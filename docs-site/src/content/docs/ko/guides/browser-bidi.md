---
title: Firefox BiDi 브라우저 Addon
description: 전용 Firefox를 설정하고 브라우저 Addon을 부착한 뒤 소유한 BiDi 연결을 확인합니다.
---

브라우저 Addon은 전용 Firefox를 띄우고 WebDriver BiDi 연결을 소유할 수 있습니다.
backend를 설정한 뒤 [Browser Lane 안내](../browser-lanes/#브라우저-addon-설치)에 따라
Addon을 부착합니다. 서버는 설정을 읽고, 부착된 worker가 브라우저의 수명을 관리합니다.

## Firefox와 프로필 준비

설치된 Firefox 실행 파일과 MASC 실행 계정이 소유하는 기존 전용 프로필 디렉터리를
사용합니다. 프로필 권한은 `0700`이어야 합니다. 설정 명령은 없는 프로필을 `0700`으로
만들고 runtime 테이블을 기록합니다. 이미 있는 프로필의 권한은 바꾸지 않으므로
실행 전에 해당 전용 디렉터리의 소유자와 권한을 확인합니다.

```bash
masc browser-lane-setup --mode bidi --base-path /path/to/workspace \
  --firefox /absolute/path/to/firefox \
  --profile /absolute/path/to/dedicated-firefox-profile \
  --port 9222
```

명시한 `--firefox`, `--profile`, `--port`는 기존 키를 갱신하고, 생략한 키는 기존 값을
유지합니다. `--base-path`는 `.masc`를 포함하는 워크스페이스입니다. `MASC_CONFIG_DIR`로
설정 루트를 바꿨다면 그곳의 실제 `runtime.toml`을 편집합니다. 같은 테이블을 덧붙이지
말고 기존 테이블을 수정합니다.

```toml
[browser.live]
enabled = true

[browser.live.bidi]
firefox = "/absolute/path/to/firefox"
profile = "/absolute/path/to/dedicated-firefox-profile"
port = 9222
```

포트 기본값은 `9222`입니다. 부착 전에 포트를 비우고 해당 전용 프로필을 사용 중인
Firefox를 닫습니다. 점유된 포트는 거부하며, 거기서 실행 중인 브라우저를 소유한
자식으로 가져오지 않습니다. 관리되는 Firefox에서 한 번 로그인하면 전용 프로필에
유지됩니다. loopback 디버깅 포트에는 인증이 없어서 다른 로컬 프로그램도 브라우저를
조작하고 쿠키를 읽을 수 있으므로 에이전트가 사용할 사이트에 한정한 프로필을 씁니다.

## 부착과 확인

1. `runtime.toml`을 바꿨다면 MASC를 재시작해 backend 설정을 읽게 합니다.
2. [설치 안내](../browser-lanes/#브라우저-addon-설치)에 따라 활성 설정 루트의
   `lane-addons/`에 번들 브라우저 패키지를 설치합니다. 기존 설치는 detach 후 새
   인스턴스로 부착해야 바뀐 backend 설정을 캡처합니다.
3. 설치의 `desired_revision`, `applied_revision`, `phase`, 설정 오류를 확인합니다.
   TOML 저장이나 `bidiHost` 설정 표시만으로 worker 부착·연결 준비가 증명되지는 않습니다.
4. `BrowserTabs`로 연결과 탭을 탐색합니다. 관측한 `clientId`와 `tabId`를 이후 읽기·조작에
   유지합니다. 일반 HTTP(S) 페이지를 읽고 새 viewport를 캡처한 뒤 포인터 입력을 보냅니다.

worker는 원래 process owner, 커널 lease, 자식의 생성·그룹 정보, 프로필 identity,
BiDi `moz:processID`를 확인한 뒤 연결을 공개합니다. 설정한 Firefox가 시작에 실패하면
해당 설치는 Ready가 되지 않으며 함께 시작한 다른 backend의 정리도 기다립니다.
비공개 worker 할당 디렉터리에 `live-firefox.log`가 있습니다. 창이 보인다는 사실과
구분해 Addon 관측에서 준비 상태와 실패를 확인합니다.

## 관리되는 브라우저 종료와 변경

설치 TOML 최상위에 `enabled = false`를 설정하고 reconciliation이 detach하도록 합니다.
파일은 서버 시작과 기존 maintenance pulse에서 읽습니다. Dashboard Refresh는 결과를
읽으며 즉시 반영을 강제하지 않습니다. 프로필이나 포트를 재사용하기 전에 detached
상태와 정리 결과를 확인합니다. 선언 삭제는 완전한 설정 목록을 읽은 뒤 반영하며,
읽지 못한 목록으로 제거를 결정하지 않습니다.

detach는 새 입력을 차단한 뒤 원래 peer와 자식의 정리를 기다립니다. 정상 종료는
`browser.close`를 한 번 보내고, 실패하면 결과 불확실 상태를 보존합니다. 프로필 내용과
안정된 claim 파일은 유지합니다. 종료된 연결은 재사용할 수 없으므로 재부착 후 새
인스턴스의 연결을 탐색합니다. 결과가 불확실한 입력은 자동 재실행하지 않습니다.

`[browser.live] enabled = false`는 다음 부착에서 이 backend를 제외합니다. 이미 설정을
캡처한 worker를 종료하지는 않습니다. 해당 설치의 Addon lifecycle로 종료합니다.

## 외부 Firefox 연결

직접 띄운 Firefox와
`masc-browser-host --bidi-url ws://127.0.0.1:9222/session`은 명시적인 외부 연결입니다.
`masc browser-lane-setup --mode host --base-path /path/to/workspace`로 launcher를
설치한 뒤 부착된 브라우저 Addon에 연결합니다. 그 브라우저의 프로세스 수명은 운영자가
관리합니다. 수동 host의 연결 진단과 관리되는 Addon의 준비 상태는 별개입니다.

## 조작 범위

BiDi는 읽을 수 있는 페이지에서 native hover·포인터·키보드·관측한 요소 조작을 제공합니다.
Firefox 내부 페이지는 스크립트를 거부해 `unavailableTabs`와 `complete: false`로 남을 수
있으며, 다른 읽을 수 있는 탭은 계속 사용할 수 있습니다. 관측한 `clientId`와 HTTP(S)
URL로 `BrowserAct action="open_tab" lane="live"`를 명시하면 기존 탭을 바꾸지 않고
새 탭을 만들 수 있습니다.

hover 후 다시 읽거나 캡처해 드러난 컨트롤을 찾습니다. drag 후에는 애플리케이션 상태를
확인합니다. 입력 영수증만으로 페이지가 drop을 수락했다고 볼 수는 없습니다. 다른 동작은
연결이 보고한 capability로 확인합니다. 브라우저 zoom·upload 등의 기능은 transport마다
같지 않습니다. Addon lifecycle 시나리오는 scripted BiDi peer를 사용하므로 모든 설치된
Firefox 빌드나 사이트에서의 동작을 증명하지 않습니다.
