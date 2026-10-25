# MacLagMonitor

macOS가 심하게 느려지거나 네트워크까지 불안정해지는 순간의 원인 후보를 낮은 평상시 부하로 기록하는 로컬 진단 도구다. 평상시에는 짧게 측정하고 강한 이상 징후에서만 상세 자료를 수집한다.

## 주요 동작
- 메모리·swap·load·Safari/WebKit·WindowServer 상태 기록.
- 기존 프로세스 표본에서 CPU·메모리 상위 실행 파일과 같은 표본 안의 제한된 부모 관계를 작은 로컬 버퍼에 보존.
- 선택적으로 관심 프로세스 정규식을 지정하면 기존 `ps` 표본을 그대로 재사용해 해당 프로세스군의 개수·합산 CPU·RSS를 기록한다. 추가 polling이나 profiler는 실행하지 않는다.
- Safari PID의 관측된 종료·재시작과 Safari/전역 WebKit 메모리 변화 기록. WebKit 수치에는 Safari 외 앱의 WebKit 프로세스가 포함될 수 있다.
- 사고 중 8초 간격 상세 측정, 높은 WebKit CPU에서만 제한적 `sample`/`log show` 실행.
- HTTPS 도달성 확인은 기본 5분 간격으로 캐시하고, 정상 시에는 primary endpoint 하나만 확인한다. primary 실패 때만 secondary endpoint를 한 번 확인하며, 실제 인터넷 장애가 감지된 순간에만 기본 게이트웨이와 외부 숫자 IP를 짧게 확인해 로컬 링크/WAN/DNS/호스트 포화 후보를 분리한다.
- 기존 macOS `*.cpu_resource.diag`와 선택적 Safari WebProcess PID↔hostname 대조 활용.
- 런타임 데이터 기본 200MB 상한. 지속적인 `log stream`, Safari 탭 polling, `powermetrics`, 상시 ping은 사용하지 않는다.

## 설치와 제어
```sh
zsh ./install.command
MONITOR="$HOME/Library/Application Support/MacLagMonitor/bin/mac-lag-monitorctl.sh"
"$MONITOR" status
"$MONITOR" snapshot
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
사고 자료는 설치 위치의 `data/incidents/`에 저장되며 `timeline.tsv`, `diagnosis.txt`, resource report 요약, 제한된 WebKit sample, Safari 도메인 후보, 직전 프로세스·Safari lifecycle 기록 등이 생성될 수 있다. 인터넷 장애가 트리거면 `network-path-probe.txt`에 당시 기본 게이트웨이·외부 숫자 IP ping, 인터페이스 카운터, 시스템 load를 함께 기록한다. schema 변경 때 보존되는 `summary-legacy-*.tsv`도 기본 30일·4개·20MB 상한으로 정리한다.

프로세스 부모 관계는 같은 `ps` 표본에서만 해석하며, 종료된 부모나 이후 PID 재사용을 추론하지 않는다. Safari 종료 관측은 강제 종료·크래시·정상 종료를 구분하지 않는다. `memory_pressure`의 free percentage는 macOS가 보고한 값이며 Activity Monitor의 메모리 압력 그래프와 같은 지표가 아니다. 높은 프로세스 수치·반복 도메인·PID↔hostname 일치는 연관 근거이지 단독 인과 증거가 아니다. 짧은 이상은 낮은 평상시 부하를 위해 놓칠 수 있다.

## 삭제와 공개 검사
```sh
zsh "$HOME/Library/Application Support/MacLagMonitor/uninstall.command"
zsh bin/check-public-tree.sh
```

공개 저장소는 allowlist 방식이며 실제 진단 데이터·설정·로컬 관리 문서는 공개 대상이 아니다.

네트워크 장애 시작 시에는 resolver·인터페이스·proxy 설정 여부·VPN 연결 수와 숫자 IP의 TCP 도달성도 한 번만 확인합니다. TCP 검사는 최대 2초이며 새 상시 polling은 없습니다. 한 대상의 실패나 동시 CPU 활동만으로 장애 원인을 확정하지 않습니다. 진단은 열 이름과 완전한 표본을 기준으로 계산하며, schema가 불명확한 과거 자료는 근거 부족으로 처리합니다.

HTTPS 검사 기록의 `primary_seconds`·`secondary_seconds`는 이름 조회·TCP 연결·TLS 완료·전체 소요 시간(초)입니다. 완료되지 않은 단계는 0일 수 있어 종료 코드와 함께 해석합니다. 기존 사고 로그에는 DHCP·네트워크 전환·Tailscale 제어 연결 이벤트도 크기·시간 상한 안에서 포함합니다.

재부팅 전후 네트워크 비교가 필요할 때 `"$HOME/Library/Application Support/MacLagMonitor/bin/mac-lag-monitorctl.sh" prepare-reboot`를 실행합니다. `data/network-reboot-before.txt`와 다음 부팅 시 한 번만 생성되는 `network-reboot-after.txt`를 비교합니다. 파일은 각각 최대 64KiB이며 다음 비교 때 갱신됩니다. 로그인 직후 기록은 네트워크·VPN 준비 전일 수 있습니다. 인터넷 검사 비활성화 설정을 존중하며 추가 상시 감시는 없습니다.

현재 연결만 즉시 진단하려면 `"$HOME/Library/Application Support/MacLagMonitor/bin/mac-lag-monitorctl.sh" network`를 실행합니다. DNS·IPv4/IPv6 경로·VPN 연결 수·프록시 사용 여부·두 HTTPS 검사의 단계별 결과를 `data/network-current.txt`에 덮어씁니다(최대 64KiB). URL·SSID·인증정보와 curl 오류 원문은 저장하지 않으며 추가 상시 감시는 없습니다.
