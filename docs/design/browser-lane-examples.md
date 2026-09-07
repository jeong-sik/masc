# Browser Lane 사용예시 — keeper 요리법

2026-09-07. PR #33738의 4개 도구로 실제로 할 수 있는 일. 설계는
`docs/design/browser-lane.md`.

도구 요약:

- `masc_browser_tabs` (lane: live/automation) — 탭 목록
- `masc_browser_read` (lane: live/automation) — 탭 텍스트 (캡 50k)
- `masc_browser_session` (automation) — keeper 전용 브라우저 열기/닫기
- `masc_browser_goto` (automation) — keeper 브라우저에서 URL 이동

## 0. 세팅 (운영자, 한 번)

```
bash connectors/browser/install-host.sh          # 토큰 + live 호스트 등록
# B(live): Firefox/Zen → about:debugging → 임시 확장 적재
# A(automation): npm i playwright && npx playwright install firefox
node connectors/browser/automation/masc-browser-automation.js &
```

## 1. "지금 뭐 봐?" — 운영자 브라우저 상태 공유 (live)

keeper가 운영자에게 뭘 보고 있는지 물어보는 흐름. 로그인 세션이 살아
있으니 비공개 페이지도 읽힌다 — 그래서 live 레인은 읽기 2동사뿐이다.

```
masc_browser_tabs {lane: "live"}
→ [{id: 3, title: "PR #33738 — browser lane", url: "https://github.com/..."}, ...]

masc_browser_read {lane: "live", tabId: 3, maxChars: 8000}
→ {text: "...PR 본문 전체...", chars: 41203}
```

보고받은 사람: "3번 탭 PR 본문 요약해줘" → keeper가 이미 읽은 텍스트로
바로 요약. WebFetch로는 못 얻는 것(로그인 뒤 페이지)이 핵심 가치.

## 2. 아침 브리핑 — 열어둔 탭 전부 요약 (live)

```
masc_browser_tabs {lane: "live"}
→ 탭 7개
masc_browser_read {lane: "live", tabId: 0..6}   (관심 탭만)
```

keeper가 각 탭을 한 줄씩 요약해서 브리핑. 북마크 폴더를 대신 읽는
용도로도 같은 패턴.

## 3. 리서치 조사 — keeper 전용 브라우저 (automation)

WebSearch→WebFetch 체인의 브라우저판. JS로 그려지는 페이지(SPA)도
읽힌다 — innerText는 렌더 후 문서를 본다.

```
masc_browser_session {action: "open"}                    # headless 기동
masc_browser_goto  {url: "https://ocaml.org/releases"}
masc_browser_read  {lane: "automation"}
→ 최신 릴리스 노트 전문
masc_browser_goto  {url: "https://..."}                  # 다음 후보
...
masc_browser_session {action: "close"}                   # 정리
```

프로파일이 유지되므로 한 번 로그인하면(수동 1회) 다음 세션부터는
해당 사이트 로그인 상태로 조사 가능 — 운영자 세션과는 분리.

## 4. 반복 점검 — 매일 같은 페이지 확인 (automation + schedule)

masc_schedule_create로 매일 아침 keeper를 깨우고:

```
masc_browser_goto {url: "https://status.example.com"}
masc_browser_read {lane: "automation", maxChars: 4000}
```

상태 페이지가 "All systems operational"이 아니면 board에 경고 글.
curl 스크래핑과 달리 JS 렌더가 필요한 상태 대시보드도 잡힌다.

## 5. PR 리뷰 보조 — 로그인 필요한 CI 화면 (live)

CI 로그가 GitHub UI 뒤(권한 체크, 첨부 아티팩트)에 있을 때:

```
masc_browser_goto 불가(live는 읽기 전용) → 운영자가 이미 그 탭을 열어둠
masc_browser_read {lane: "live", tabId: 12}
```

"그 탭 열어둬" → keeper가 읽어서 로그 분석. 이 흐름이 live 레인의
주 수요처다: 조작은 사람이, 읽기는 keeper가.

## 경계 다시 보기

- live에서 `masc_browser_session`/`goto`를 호출하면 즉시 거부된다
  (verb_allowed_on_live). automation에서만 조작.
- click/submit 동사는 act-게이트 설계 전까지 프로토콜에 없다.
- page.read 캡 50k — 더 길면 [TRUNCATED] 마커와 함께 잘린다.
