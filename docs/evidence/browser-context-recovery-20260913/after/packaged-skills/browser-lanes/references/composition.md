# 관측한 영역·링크 이동·탭 활성화

필요할 때만 browser-lanes와 함께 읽는다. 현재 도구 목록과 스키마가 우선한다.

## 관측한 영역과 짧은 composition

조작 순서의 `after`와 결과 전달의 output template을 구분한다. 후보 선택이나
예상하지 못한 화면에서는 관측하고 판단한다. 성공은 요청한 대상·범위·결과로 판정하고
단계별 실패와 출처를 남긴다. 중간 실패 뒤에는 이미 적용된 단계와 결과가 불명확한
단계를 재관측해 남은 작업을 결정한다. 전체 묶음을 무조건 재실행하지 않는다.

현재 스키마가 지원하면 BrowserRead의 `regions`로 의미 영역 목록을 읽고,
반환된 documentId/nodeId를 `scope`로 전달해 `scene`을 읽는다. 인자를 무시한
전체 페이지 응답을 영역 읽기의 성공으로 받아들이지 않는다. 같은 영역을
새로 읽을 때도 scope를 유지하고, reload/detach 거절은 새 관측으로 해소한다.

composition은 `keeper_skill`의 Available instruction 목록에서 읽는 문서가 아니라
`keeper_compose_<name>` 형태로 노출되는 호출 도구다. 현재 도구 목록에서 정확한
이름과 입력 스키마를 확인하고 호출한다. 사이트별 판단 규칙은 instruction Skill에서
필요할 때 읽는다. 도구가 없으면 composition 지원을 가정하거나 `keeper_skill`로
composition을 읽으려 하지 않는다.

관측한 automation 탭에서 이미 아는 HTTP(S) URL의 본문을 바로 읽을 때는
`keeper_compose_browser-navigate-content`를 사용할 수 있다. 이동 결과의 실제 URL을
이어지는 `scene` 읽기에 전달한다. 반환된 본문이 요청한 내용을 충족하면 그 결과를
사용하고, 범위가 부족하거나 잘렸을 때 필요한 영역을 다시 관측한다. 영역 선택이 먼저
필요한 화면에서는 `keeper_compose_browser-navigate-regions`로 영역 목록부터 읽는다.
두 도구를 관례적으로 연달아 호출하지 않는다. 이들은 automation 전용이며 live 로그인
세션을 대신하지 않는다. 본문 읽기만 실패했다면 성공한 이동을 반복하지 않고 같은
탭에서 BrowserRead만 재시도한다. 제목·대상·범위를 확인하는 사이트 판단은 유지한다.

BrowserInteract 클릭 응답은 조작 접수와 원래 탭 정체를 나타낸다. 목적지 로딩 완료나
SPA 채널 내용 전환을 증명하지 않는다. 링크가 새 탭을 열 수 있으므로 BrowserTabs와
페이지 관측에서 목적지를 식별한 후 그 탭의 영역을 읽는다. URL만 바뀌어도 메시지는
이전 채널일 수 있다. 요청 채널의 제목·영역·본문을 확인하고, 전환 중이거나 목적지가
아직 관측되지 않으면 미확인으로 남겨 다음 관측에서 판단한다. 관측 실패 때문에
이미 적용된 클릭을 재실행하지 않는다.

관측된 같은 탭 HTTP(S) 링크를 따라갈 때 현재 도구 목록에 있는
`keeper_compose_browser-live-click-content`로 목적지의 보이는 본문을 바로 읽을 수 있다.
영역을 먼저 골라야 하는 화면에서는 `keeper_compose_browser-live-click-regions`를
선택한다. 본문이 요청한 내용을 충족하면 추가 영역 읽기를 관례적으로 실행하지 않는다.
두 경로는 실제 href를
검증하고 직접 이동하므로 클릭 핸들러를 실행하지 않는다. 새 창 대상·다운로드는
이동 전에 거절된다. 후속 본문 또는 영역 읽기는 `destinationUrl`을 `expectedUrl`로 확인한다.
전환 오류이면 같은 clientId/tabId를 expectedUrl 없이 읽어 실제 URL과 내용을
확인한다. 원래 urlBefore이면 아직 이동 중일 수 있다. 다른 URL이면 리다이렉트·
정규화·로그인 화면일 수 있으므로 자동 승인하지 않는다. 사이트 Skill로 workspace·
채널·제목·본문을 검증한 뒤 실제 관측 URL을 새 expectedUrl로 지정한다. 미확인
목적지는 미확인으로 남긴다. 원래 URL 검사나 이동을 무조건 반복하지 않는다.
일치하는 URL도 사이트 내용의 준비 완료는 아니며 채널 제목과 본문을 검증한다.

For same-URL follows, preserve the returned `navigationSource` together with
`expectedUrl` on read-only retries. The destination read must observe a new
document ID before accepting a reload. Do not drop this guard to accept the
old document; different-URL SPA navigation may retain its document identity.

Keep navigationSource when omitting expectedUrl to inspect a possible redirect;
a source-URL observation from the original document is still pending.

## Explicit live tab activation

When an observed live tab is inactive and its body still shows pending or previous
content after a channel transition, `BrowserInteract action=activate_tab` can select
that exact tab. This requires extension 0.6.0 or newer and the currently advertised
action schema. Preserve the observed clientId, tabId and expectedUrl. This is an
explicit action, not an automatic step in every read or composition. It does not
focus the browser window, change the URL or reload. Automation rejects this action.

An active=true receipt confirms tab selection only. Read the same tab again and
verify the requested channel body and scope before collecting context. If activation
fails after dispatch, inspect the tab state before retrying; do not replay a prior
link click or follow merely because the subsequent observation is unavailable.
