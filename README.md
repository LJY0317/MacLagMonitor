# MacLagMonitor

macOS가 심하게 느려지거나 네트워크까지 불안정해지는 순간의 원인 후보를 낮은 평상시 부하로 기록하는 로컬 진단 도구다. 평상시에는 짧게 측정하고 강한 이상 징후에서만 상세 자료를 수집한다.

## 주요 동작
- 메모리·swap·load·Safari/WebKit·WindowServer 상태 기록.
- 사고 중 8초 간격 상세 측정, 높은 WebKit CPU에서만 제한적 `sample`/`log show` 실행.
- 인터넷 장애가 실제 감지된 순간에만 기본 게이트웨이와 외부 숫자 IP를 짧게 확인해 로컬 링크/WAN/DNS/호스트 포화 후보를 분리한다.
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

인터넷 도달성 확인을 끄려면 `config.conf`에 `INTERNET_CHECK_ENABLED=0`을 설정한다.

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
사고 자료는 설치 위치의 `data/incidents/`에 저장되며 `timeline.tsv`, `diagnosis.txt`, resource report 요약, 제한된 WebKit sample, Safari 도메인 후보 등이 생성될 수 있다. 인터넷 장애가 트리거면 `network-path-probe.txt`에 당시 기본 게이트웨이·외부 숫자 IP ping, 인터페이스 카운터, 시스템 load를 함께 기록한다.

높은 프로세스 수치·반복 도메인·PID↔hostname 일치는 연관 근거이지 단독 인과 증거가 아니다. 짧은 이상은 낮은 평상시 부하를 위해 놓칠 수 있다.

## 삭제와 공개 검사
```sh
zsh "$HOME/Library/Application Support/MacLagMonitor/uninstall.command"
zsh bin/check-public-tree.sh
```

공개 저장소는 allowlist 방식이며 실제 진단 데이터·설정·로컬 관리 문서는 공개 대상이 아니다.
