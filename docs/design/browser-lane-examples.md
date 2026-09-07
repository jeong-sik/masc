# Browser Lane 사용 흐름

Browser는 사이트 구분 없이 페이지를 읽는 공통 도구다. Keeper에 보이는
이름은 `BrowserTabs`, `BrowserRead`, `BrowserSession`, `BrowserGoto`이며,
등록 이름은 각각 `masc_browser_tabs`, `masc_browser_read`,
`masc_browser_session`, `masc_browser_goto`다.

## 연결

운영자가 사용하는 Firefox/Zen은 `live`, Keeper가 URL을 열어 조사하는
격리 Firefox는 `automation`이다. 두 브라우저는 로그인 세션을 공유하지 않는다.

Live 호스트를 설치하고 Firefox `about:debugging`에서 확장을 적재한다.

```sh
bash connectors/browser/install-host.sh \
  --binary /path/to/masc-browser-host \
  --base-path /path/to/workspace \
  --server http://127.0.0.1:8935
```

확장 manifest: `connectors/browser/extension/manifest.json`.
Automation은 geckodriver를 실행하고, resolved configuration directory의
`runtime.toml`에 endpoint를 설정한 뒤 MASC를 재시작한다.

```sh
geckodriver --host 127.0.0.1 --port 4444
```

```toml
[browser]
webdriver_url = "http://127.0.0.1:4444"
```

자세한 연결 계약은 [native Firefox](native-firefox-lane.md)에 있다.
TUI에서는 `:` → `go Browser Lane`, `l` / `a`로 source를 선택한다.

## 열린 업무 화면에서 근거 찾기

“열어둔 PR에서 실패한 CI 원인을 확인해줘” 같은 요청이면 우선 탭 목록에서
해당 제목과 URL을 찾는다. 배열 순서로 id를 추측하지 않는다.

```json
BrowserTabs {"lane":"live"}
BrowserRead {"lane":"live","tabId":73,"maxChars":12000}
```

위 `73`은 예시이며 실제 첫 호출이 반환한 id를 사용한다. 읽은 URL과
오류 내용을 연결해 설명한다. 목록에 있다는 사실만으로 페이지를 읽었다고
하지 않는다. 현재 렌더된 내용에 로그가 없으면 확인한 범위를 명시한다.

같은 흐름을 이슈, 문서, 대시보드, 대화 페이지에 쓴다. 사이트별 레인이
필요하지 않으며, 업무에 필요한 탭만 선택하면 된다.

## 여러 페이지 비교

“열어둔 요구사항 문서와 구현 설명의 차이를 찾아줘”라면 `BrowserTabs`에서
두 페이지를 찾고 각각의 id로 `BrowserRead`를 호출한다. 읽기 결과를 URL별로
구분해 차이와 근거를 작성한다. `truncated=true`이면 필요에 따라 `maxChars`를
늘려 다시 읽을 수 있다(최대 100,000 Unicode code points). 가상 스크롤이나
접힌 영역의 내용까지 포함된다고 가정하지 않는다.

## 직접 URL을 열어 조사

```json
BrowserSession {"action":"open"}
BrowserGoto {"url":"https://ocaml.org/releases"}
BrowserRead {"lane":"automation","maxChars":12000}
```

`BrowserGoto` 후 실제 `BrowserRead` 결과로 내용을 확인한다. 다음 URL도
같은 순서로 읽고, 결과에는 관측한 출처를 붙인다. 자동화 세션은 공유 자원이므로
이번 작업이 새로 연 세션인지 확인하고 닫는다. 기존 세션을 재사용했다면
다른 작업의 브라우저를 임의로 종료하지 않는다.

## 반복 관측

동일 페이지를 나중에 다시 확인하려면 `masc_schedule_create`로 후속 작업을
예약하고, 깨어난 턴에서 페이지를 새로 읽는다. 이전 관측과 현재 관측을
비교해 달라진 내용을 근거와 함께 보고한다. Browser가 자체적으로 모든
탭을 감시하거나 특정 웹앱을 주기적으로 수집하지는 않는다.

## 관측 범위

`BrowserRead`는 렌더된 텍스트, URL, 제목, 전체 문자 수(`chars`)와 잘림
여부(`truncated`)를 반환한다. 기본 반환 한도는 50,000 code points다.
텍스트 읽기는 스크린샷이나 시각적 배치 검증이 아니다. 현재 도구는 탭
목록·텍스트 읽기와 automation 세션·URL 이동을 지원한다. 클릭·입력·제출은
별도 동작으로 구현되어 있지 않다.
