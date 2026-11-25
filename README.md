# MacLagMonitor

macOS의 기본 진단 기록을 재사용하고, 시스템 지연·메모리 부족·네트워크 장애 때만 추가 증거를 기록하는 로컬 진단 도구입니다. 터미널과 AI 에이전트에서 기존 OS 기록과 장애 증거를 함께 조회할 수 있습니다.

## 동작 방식

- **평상시:** macOS가 보존하는 장기 시스템 이력을 별도로 수집하지 않습니다. 위험 수준 메모리 압력과 시스템 네트워크 경로 변경은 OS 이벤트로 감지합니다. CPU·압축 메모리·Safari/WebKit·실제 인터넷 도달성처럼 동일한 실시간 이벤트가 없는 항목만 기존 감지 표본에서 확인합니다.
- **최근 증거:** 재부팅·장애 직전의 감지 입력, 프로세스 PID·같은 표본의 부모 관계, 네트워크 경로 및 Safari 관측 이벤트만 제한된 버퍼에 보존합니다. 정상 상태의 누적 시스템 timeline은 생성하지 않습니다.
- **장애:** 일반 성능 조건은 연속 두 표본, OS 위험 메모리 이벤트·인터넷 실패·특정 크래시 처리 신호는 즉시 상세 진단을 시작합니다. 기본 8초 간격으로 최대 4분 수집하며, 실제 정상 표본이 연속 확인되면 일찍 종료합니다. 지속되는 같은 이상은 episode 상태로 중복 진단을 억제합니다.
- **조회:** CLI가 PowerLog·Unified Log·DiagnosticReports와 보존한 장애 증거를 요청 시 읽습니다. 별도 상시 수집 프로세스, PowerLog 복제 DB, 전력 센서 polling, 지속적인 log stream이나 profiler는 없습니다. 네이티브 이벤트 대기는 기존 sleep 자식을 대체합니다.

감지 간격 기본값은 일반 충전기 연결 120초, 일반 배터리 300초, 저전력 모드 또는 모든 화면 잠자기 600초입니다. 이벤트가 오면 예정 시간 전에 감지할 수 있습니다. 잠자기를 방지하거나 예약 깨우기를 설정하지 않습니다. 짧은 CPU·네트워크 이상은 감지 사이에서 놓칠 수 있습니다.

## 설치·업데이트·제어

macOS에서 Apple Command Line Tools 또는 Xcode가 필요합니다. 소스 설치 시 Swift 네이티브 모듈을 한 번 빌드합니다. 별도 Python 런타임, Homebrew 패키지, 서버 또는 관리자 권한을 요구하지 않습니다.

```sh
# Apple 개발 도구가 없는 경우 먼저 설치
xcode-select --install
git clone https://github.com/LJY0317/MacLagMonitor.git
cd MacLagMonitor
zsh ./install.command
```

기존 설치는 같은 설치 명령으로 갱신하며 사용자 설정과 진단 자료를 보존합니다. 제거된 설정 키만 정리하고 기존에 선택한 감지 간격은 변경하지 않습니다. 기본 설치 위치는 `~/Library/Application Support/MacLagMonitor`입니다. 사용자 로컬 명령 링크는 `~/.local/bin/maclagmonitor`이며, 해당 디렉터리가 PATH에 없으면 다음과 같이 실행할 수 있습니다.

```sh
"$HOME/.local/bin/maclagmonitor" help
# 링크를 설치하지 못한 경우에도 기존 CLI를 사용할 수 있습니다.
"$HOME/Library/Application Support/MacLagMonitor/bin/mac-lag-monitorctl.sh" status
```

실제 설정은 설치 위치의 `config.conf`입니다. 변경 후 `maclagmonitor restart`를 실행합니다.

## 읽기 전용 CLI

```sh
maclagmonitor status --json
maclagmonitor sources --last 7d --json
maclagmonitor query power --last 24h --json
maclagmonitor query power --last 7d --group-by day --json
maclagmonitor query sleep --last 7d --json
maclagmonitor query sleep --events --last 30m --json
maclagmonitor query battery --last 24h --json
maclagmonitor query cpu --last 24h --limit 10 --json
maclagmonitor query memory --last 24h --json
maclagmonitor query network --last 24h --json
maclagmonitor query incidents --last 7d --json
maclagmonitor query timeline --last 24h --group-by hour --json
maclagmonitor query logs --last 30m --json
maclagmonitor query reports --last 7d --json
maclagmonitor query history --last 24h --json
```

| 조회 | 데이터 소스 및 범위 |
|---|---|
| power / battery / sleep | PowerLog 현재 DB·기간에 맞는 압축 아카이브, 전력/에너지/배터리와 잠자기·Dark Wake·유휴 구간 |
| cpu / memory | PowerLog 앱/coalition의 CPU 시간·GPU/ANE 에너지·I/O 및 OS 메모리 상태 |
| network | PowerLog 전송량과 MacLagMonitor의 경로·도달성 전환 |
| incidents / timeline | 자체 장애 요약, OS 자원 이력, 최근 감지 증거의 통합 조회 |
| logs / reports | Unified Log의 관련 error/fault 집계 및 DiagnosticReports 파일 참조 |
| history | 이전 버전의 동결된 요약과 최근 감지 버퍼; 새 누적 이력은 생성하지 않음 |

`query sleep --events`는 PowerLog 구간에 더해 기존 Unified Log에서 잠자기, Dark Wake, Full Wake, 화면 켜짐·꺼짐과 잠금 해제를 시간순으로 표시합니다. `sleep_events`는 자체 조회 상태와 전체 일치 건수를 반환하며, `--limit`는 표시할 최신 이벤트 수를 제한합니다. 깨우기 사유와 블루투스 기기명은 기록에서 확인될 때 표시합니다. 이벤트가 없으면 로그가 보존되지 않았거나 해당 macOS 버전의 기록 형식이 다를 수 있습니다. 이 옵션은 요청 시에만 실행되며 읽은 기록은 저장하지 않습니다.

공통 시간 옵션은 `--last 24h` 또는 `--from 2026-01-01T00:00:00+00:00 --to 2026-01-02T00:00:00+00:00`입니다. `power`, `sleep`, `timeline`은 `--group-by hour|day`를 지원합니다. `--limit N`은 세부 결과 수를 제한합니다. 날짜별 구간은 로컬 시간대를 사용하고 타임스탬프는 ISO 8601로 반환합니다. 기본 출력은 읽기 좋은 JSON, `--json`은 압축된 기계용 JSON입니다.

AI 연동은 `help`와 `sources`로 기능·데이터 가용성을 확인하고, JSON의 `schema_version`, `status`, `requested_range`, 실제 관측 범위, 출처·누락·커버리지를 사용합니다. `partial`/`unavailable`과 `null`은 정상 또는 0을 뜻하지 않습니다. 읽기 명령은 모니터를 실행하거나 새 진단·네트워크 요청·기록을 생성하지 않습니다. PowerLog의 읽기 권한 또는 스키마가 부족하면 해당 조회만 제한되며 모니터링은 독립적으로 작동합니다.

### 전력 정보의 해석

PowerLog는 Apple의 비공개 형식이며 보존 기간·필드·단위가 OS/기기별로 달라질 수 있습니다. 전력은 관측된 누적 카운터 차이를 시간 가중 평균하여 계산한 추정 W·Wh·kWh입니다. 최대 순간 표본과 최대 구간 평균은 구분합니다. 전원 전환, 리셋, 불연속 카운터나 신뢰할 수 없는 구간은 제외하고 커버리지를 표시합니다. 시스템 부하, 외부 DC 입력, 배터리 충전·방전 추정량은 별개이며 콘센트 측정값이 아닙니다. 배터리 전류·전압의 희소 표본으로 계산하는 에너지는 특히 제한적입니다. 잠자기·Dark Wake의 분류는 관측된 OS 상태의 해석이며 사용자 유휴는 화면 꺼짐이나 사람의 수면을 입증하지 않습니다. 압축 아카이브는 조회 중 임시 해제한 뒤 정리하고 영구 복사본을 만들지 않습니다.

## 수동 진단 및 운영

```sh
maclagmonitor snapshot       # 새 한 번의 TSV 표본, 운영 버퍼에는 쓰지 않음
maclagmonitor diagnose       # 새 상세 진단을 저장
maclagmonitor network        # 새 네트워크 진단을 저장
maclagmonitor prepare-reboot
maclagmonitor test-trigger
maclagmonitor restart
maclagmonitor logs           # 기존 로컬 데이터 폴더 열기
```

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

문제가 생기면 연결을 바꾸거나 앱을 종료하기 전에 `maclagmonitor diagnose`를 실행한다. 현재 자원·전원·새 HTTPS 검사·DNS·네트워크 경로·OS 오류 요약을 한 번 저장한다. `maclagmonitor network`는 경로와 두 HTTPS 검사만 `data/network-current.txt` 한 파일에 덮어쓴다(최대 64KiB).

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

재부팅 비교는 `maclagmonitor prepare-reboot`로 예약한다. `data/network-reboot-before.txt`와 다음 실제 부팅의 `network-reboot-after.txt`를 비교한다(각 64KiB, 다음 비교 때 갱신). 로그인 직후에는 네트워크·VPN이 준비 중일 수 있다.

인터넷 검사 비활성화 설정을 존중하며 새 상시 로그 스트림·핑·프로파일러·타이머를 추가하지 않는다. 보관은 개수 대신 기간·용량으로 제한한다. 기본 전체 200MiB, 사고 150MiB/7일, 업그레이드 전 동결된 요약 20MiB/30일이며 오래된 자료부터 정리한다. 정상 감지 버퍼는 기본 30분·128KiB, 프로세스 버퍼는 512KiB 이내로 유지한다. 이미 생성된 장애 증거는 기존 보관 정책을 따른다.

## 삭제와 공개 검사
```sh
maclagmonitor uninstall
```

개발 검증(선택, 설치 상태에서 실행):
```sh
zsh bin/check-public-tree.sh
# Optional developer regression (Python 3, synthetic DB only)
python3 tests/verify-query.py "$HOME/Library/Application Support/MacLagMonitor/bin/maclagmonitor-native"
```

공개 저장소는 allowlist 방식이며 실제 진단 데이터·설정·로컬 관리 문서는 공개 대상이 아니다. 현재 Apple Silicon macOS에서 검증했으며 다른 OS 버전·Intel Mac의 PowerLog 호환성은 별도로 확인해야 한다.
