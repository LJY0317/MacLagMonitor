# MacLagMonitor

MacLagMonitor는 macOS가 심하게 느려지거나 인터넷 연결까지 불안정해지는 순간의 원인 후보를 **낮은 평상시 부하**로 기록하는 로컬 진단 도구입니다.

평상시에는 120~600초 간격으로 짧게 측정하고, 강한 이상 징후가 확인될 때만 4분 동안 상세 자료를 수집합니다. 지속적인 `log stream`, Safari 탭 상시 감시, `powermetrics` 상시 실행은 하지 않습니다.

## 주요 기능

- 메모리, compressor, swap, load, Safari/WebKit, WindowServer 상태 기록
- 사고 중 8초 간격 상세 측정
- 높은 WebKit CPU에서만 2초 `sample`, 사고당 최대 2회
- 필요한 경우에만 제한된 `log show` 실행
- macOS의 기존 `*.cpu_resource.diag`를 재사용한 사후 분석
- Safari/WebKit 사고의 반복 도메인 후보 비교
- 전체 런타임 데이터 기본 200MB 상한

## 설치

```sh
zsh ./install.command
```

기본 설치 위치:

```text
~/Library/Application Support/MacLagMonitor
```

설치 후:

```sh
MONITOR="$HOME/Library/Application Support/MacLagMonitor/bin/mac-lag-monitorctl.sh"
"$MONITOR" status
"$MONITOR" snapshot
"$MONITOR" test-trigger
"$MONITOR" restart
"$MONITOR" logs
```

실제 설정은 설치 디렉터리의 `config.conf`이며, 저장소에는 기본값인 `config.example.conf`만 포함됩니다.

## 개인정보와 네트워크

진단 데이터는 로컬에만 저장하며 별도 텔레메트리 서버는 없습니다.

`CAPTURE_SAFARI_DOMAINS=1`이면 Safari/WebKit 관련 사고 순간에만 Safari 탭의 **호스트 이름**을 읽을 수 있습니다. macOS가 Safari 자동화 권한을 요청할 수 있습니다. 전체 URL, 페이지 제목, 검색어, 본문, 쿠키, 비밀번호는 의도적으로 저장하지 않습니다.

인터넷 도달성 확인은 기본적으로 Apple과 Cloudflare의 작은 HTTPS 엔드포인트를 사용합니다. 원하지 않으면 `config.conf`에서 다음 값을 설정합니다.

```sh
INTERNET_CHECK_ENABLED=0
```

## 사고 기록

사고 자료는 설치 디렉터리의 `data/incidents/` 아래에 저장됩니다. 대표적으로 `timeline.tsv`, `diagnosis.txt`, macOS resource report 요약, 제한된 WebKit sample과 Safari 도메인 후보가 생성될 수 있습니다.

반복 도메인이나 높은 프로세스 수치는 **연관 근거**이며 특정 사이트·확장·WebKit 버그의 인과를 단독으로 증명하지 않습니다.

## 삭제

```sh
zsh "$HOME/Library/Application Support/MacLagMonitor/uninstall.command"
```

## 공개 저장소 안전장치

이 저장소의 `.gitignore`는 **기본적으로 모든 파일을 무시하고 검토된 소스 파일만 허용하는 allowlist 방식**입니다. 실제 `data/`, `logs/`, `state/`, `config.conf`와 로컬 관리 문서는 공개 대상이 아닙니다.

공개 전 검사:

```sh
zsh bin/check-public-tree.sh
```

## 한계

MacLagMonitor는 실시간 프로파일러가 아닙니다. 짧은 이상은 놓칠 수 있으며, 이는 평상시 CPU·배터리 비용을 낮추기 위한 의도된 절충입니다. Safari의 공개 인터페이스만으로 WebKit PID와 정확한 탭·iframe을 항상 일대일로 확정할 수도 없습니다.
