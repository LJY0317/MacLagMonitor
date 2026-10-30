# MacLagMonitor

macOS가 심하게 느려지거나 네트워크까지 불안정해지는 순간의 원인 후보를 낮은 평상시 부하로 기록하는 로컬 진단 도구다. 평상시에는 짧게 측정하고 강한 이상 징후에서만 상세 자료를 수집한다.

## 주요 동작
- 메모리·swap·load·Safari/WebKit·WindowServer 상태 기록.
- 기존 프로세스 표본에서 CPU·메모리 상위 실행 파일과 같은 표본 안의 제한된 부모 관계를 작은 로컬 버퍼에 보존.
- 선택적으로 관심 프로세스 정규식을 지정하면 기존 `ps` 표본을 그대로 재사용해 해당 프로세스군의 개수·합산 CPU·RSS를 기록한다. 추가 polling이나 profiler는 실행하지 않는다.
- Safari PID의 관측된 종료·재시작과 Safari/전역 WebKit 메모리 변화 기록. WebKit 수치에는 Safari 외 앱의 WebKit 프로세스가 포함될 수 있다.
- 사고 중 8초 간격 상세 측정, 높은 WebKit CPU에서만 제한적 `sample`, 관련 사고에서만 제한적 OS 로그 조회.
- HTTPS 도달성 확인은 기본 5분 간격으로 캐시하고, 정상 시에는 primary endpoint 하나만 확인한다. primary 실패 때만 secondary endpoint를 한 번 확인하며, 실제 인터넷 장애가 감지된 순간에만 기본 게이트웨이와 외부 숫자 IP를 짧게 확인해 로컬 링크/WAN/DNS/TCP·TLS 실패 경계를 비교한다.
- 기존 macOS `*.cpu_resource.diag`와 선택적 Safari WebProcess PID↔hostname 대조 활용.
- 런타임 데이터 기본 200MB 상한. 지속적인 `log stream`, Safari 탭 polling, `powermetrics`, 상시 ping은 사용하지 않는다.

## 설치와 제어
```sh
zsh ./install.command
MONITOR="$HOME/Library/Application Support/MacLagMonitor/bin/mac-lag-monitorctl.sh"
"$MONITOR" status
"$MONITOR" snapshot
"$MONITOR" diagnose
"$MONITOR" test-trigger
"$MONITOR" restart
"$MONITOR" logs
```

기본 설치 위치는 `~/Library/Application Support/MacLagMonitor`이며 실제 설정은 설치 위치의 `config.conf`다.

## 개인정보와 네트워크
진단 데이터는 로컬에 저장하며 별도 텔레메트리 서버가 없다. `CAPTURE_SAFARI_DOMAINS=1`이면 사고 순간에만 Safari 탭 hostname을 읽을 수 있으며 전체 URL·제목·검색어·본문·쿠키·비밀번호는 저장하지 않는다.

인터넷 도달성 확인을 끄려면 `config.conf`에 `INTERNET_CHECK_ENABLED=0`을 설정한다. 기본 HTTPS 확인 간격은 `INTERNET_PROBE_INTERVAL_SECONDS=300`이며, 짧은 장애를 더 빨리 포착하는 대신 background network wakeup을 늘릴 필요가 있을 때만 줄이는 것을 권장한다.

Safari/WebKit 분석을 강화하려면 선택적으로 Safari Internal Debug Menu의 `Show Web Process IDs In Page Titles`를 사용할 수 있다. MacLagMonitor가 이 설정을 자동 변경하지는 않는다.

```sh
defaults write com.apple.Safari IncludeInternalDebugMenu -bool true
# Safari 재실행 후: Debug → Miscellaneous Flags → Show Web Process IDs In Page Titles
```

MacLagMonitor 때문에만 활성화했다면 Safari 종료 후 다음 preference를 삭제할 수 있다.

```sh
defaults delete com.apple.Safari DebugShowProcessIDsForPerTabWebProcesses
defaults delete com.apple.Safari IncludeInternalDebugMenu
```

## 사고 기록과 한계

사고 자료는 설치 위치의 `data/incidents/`에 저장된다. `timeline.tsv`와 `diagnosis.txt`가 요약이며, 프로세스·Safari lifecycle, macOS resource report, 제한된 WebKit sample이 추가될 수 있다. CPU 부하와 네트워크 실패는 별개 증거로 다루며 동시 발생만으로 인과를 판단하지 않는다. 프로세스 측정 실패도 네트워크 감지·진단을 막지 않는다.

프로세스 부모 관계는 같은 표본 안에서만 해석한다. Safari 종료 관측은 정상 종료·강제 종료·크래시를 구분하지 않는다. `memory_pressure`의 free percentage는 Activity Monitor의 메모리 압력 그래프가 아니다. `pmset` 전원 경고를 기록하지만 팬 RPM·온도는 직접 측정하지 않는다.

## 네트워크 진단

문제가 생기면 연결을 바꾸거나 앱을 종료하기 전에 `"$MONITOR" diagnose`를 실행한다. 현재 자원·전원·새 HTTPS 검사·DNS·네트워크 경로·OS 오류 요약을 한 번 저장한다. `"$MONITOR" network`는 경로와 두 HTTPS 검사만 `data/network-current.txt` 한 파일에 덮어쓴다(최대 64KiB).

자동 수집은 다른 성능 사고를 기록하는 도중 생긴 네트워크 실패도 포착한다. 첫 실패와 첫 복구를 같은 사고 폴더에 남기며, 사고의 상세 수집 기간이 끝난 뒤에도 기존 정기 표본에서 복구를 관측하면 해당 폴더에 추가한다. 만료·삭제된 사고는 다시 만들지 않는다. 수동 `diagnose`는 그 순간의 기록이다.

| 파일 | 내용 |
|---|---|
| `network-path-probe.txt` | 실패 당시 경로·resolver·프록시 사용 여부·VPN 수·게이트웨이/숫자 IP 도달성, 원래 HTTPS 검사 시각 |
| `dns-path-probe.tsv` | 인터페이스/보조/기준 DNS의 A·AAAA 응답 상태·시간·실제 인터페이스 경로 |
| `network-recovery-context.txt`, `dns-recovery-probe.tsv` | 첫 복구 시점의 같은 맥 공통 네트워크 상태 |
| `network-extensions.txt`, `network-recovery-extensions.txt` | OS가 공개하는 네트워크 시스템 확장 상태; 앱 방식 VPN·필터가 모두 나열되는 것은 아님 |
| `recent-system-events.log` | Wi-Fi·DHCP·DNS 서비스·네트워크 확장 오류 등의 분 단위 종류·로그 수·처음/마지막 시각, 숫자형 무선 품질 |
| `system-log-capture-status.txt` | 조회 완료·실패·부분 수집·시간/용량 한도 |

장애·첫 복구의 경로 자료에는 `1.1.1.1`과 기존 HTTPS 검사 접속 IP의 실제 경로를 포함합니다. `network-events.tsv`의 `path-change`는 기존 표본에서 관측한 로컬 IP·기본/외부 경로 변경이며 정확한 전환 시각이나 앱 활성 상태를 뜻하지 않습니다. 변경 시 HTTPS 캐시를 무효화합니다. 외부 경로 표본은 라우팅 테이블 조회이며 추가 패킷이나 이름 조회를 보내지 않습니다. 이벤트는 사고 보관 기간과 기존 용량 한도로 정리합니다.

직접 DNS 검사는 설정된 두 HTTPS 호스트만 사용한다. 현재 인터페이스 DNS 하나, 보조 DNS 하나(있을 때), 기준 `1.1.1.1`에 각각 A·AAAA를 한 번·1초 응답 예산으로 조회하며 서버/호스트 묶음은 병렬 실행한다. 시스템 split-DNS 선택을 우회하지만 실제 VPN 경로를 우회하지는 않는다. 공용 DNS 차단도 가능하므로 한 결과만으로 특정 서버·VPN·공유기를 원인으로 확정하지 않는다.

HTTPS의 `primary_seconds`·`secondary_seconds`는 DNS·TCP·TLS 완료·전체 시간이다. 미완료 단계는 0일 수 있어 종료 코드와 함께 해석한다. 두 검사가 HTTP 오류를 반환하면 `offline-http`로 구분하며 정상으로 집계하지 않는다. 이는 검사 대상의 오류 관측이지 맥의 모든 인터넷 통신 실패를 증명하지는 않는다.

정기 HTTPS는 기본 5분 캐시를 쓰므로 짧은 장애를 놓칠 수 있다. 기존 경로 조회에서 게이트웨이/인터페이스 변경을 관측하면 캐시를 무효화한다. 단발 성공은 지속적인 안정성의 증거가 아니다. 로그 수는 독립 오류 횟수가 아니며, 조회 실패나 기록 부재도 정상의 증거가 아니다. 원문·SSID·BSSID·키체인 식별자·페이지 내용은 새 시스템 이벤트 요약에 보존하지 않는다. 특정 앱의 중계 요청·인증·대화 로그는 수집하지 않는다.

재부팅 비교는 `"$MONITOR" prepare-reboot`로 예약한다. `data/network-reboot-before.txt`와 다음 실제 부팅의 `network-reboot-after.txt`를 비교한다(각 64KiB, 다음 비교 때 갱신). 로그인 직후에는 네트워크·VPN이 준비 중일 수 있다.

인터넷 검사 비활성화 설정을 존중하며 새 상시 로그 스트림·핑·프로파일러·타이머를 추가하지 않는다. 보관은 개수 대신 기간·용량으로 제한한다. 기본 전체 200MiB, 사고 150MiB/7일, 과거 요약 20MiB/30일이며 오래된 자료부터 정리한다.

## 삭제와 공개 검사
```sh
zsh "$HOME/Library/Application Support/MacLagMonitor/uninstall.command"
zsh bin/check-public-tree.sh
```

공개 저장소는 allowlist 방식이며 실제 진단 데이터·설정·로컬 관리 문서는 공개 대상이 아니다.
