# 네 화면 읽기 개선의 두 번째 검토

검토 요청은 목표·작업·게시판·기억의 일관성을 한 번 더 확인하는 것이다.
기존 구현 #50698의 `db182da9c2529fcda92bbf6cfe8129ad7f80dcec`와
base `636c12604910ab0252753d594fcd64f95725b6b9`를 다시 읽었다.
수정은 Native Stack #50678의 당시 맨 위 #50707
`cd2523bd49ab21b66d207ed9a732a8d9bbdcb3a0`를 base로 한 별도 층이다.
스택 전체의 병합 승인으로 해석하지 않는다.

| 발견 | 수정 | 의미 검사 |
| --- | --- | --- |
| Memory에 보이는 `중단됨`, `스냅샷 없음`, `memory observed`로 검색해도 해당 Keeper가 남지 않는다 | 같은 typed 상태에서 표시와 canonical·KO·EN 검색어를 만들고 목록 필터와 커서 검색이 함께 사용한다 | 입력 중·적용된 검색, 두 UI 언어에서 조회 결과와 선택한 Keeper ID가 일치하는지 확인하는 사례 추가 |
| health가 해석하지 못한 Keeper 행이 전체 사실 조회에서 빠진다. 거절된 행만 있으면 전체를 읽은 빈 목록처럼 보인다 | 당시 health의 named·anonymous 거절을 facts 병합에 필수 인자로 전달하고 읽힌 사실과 같은 응답에 누락 범위를 보존한다 | 읽힌 사실과 거절의 공존, 거절만 있는 경우, 각 사유 보존, 총수 미확인과 알려진 빈 저장소의 0을 구별하는 사례 추가 |

두 번째 문제의 producer 누락은 기존 base에도 있었다. 이번 수정이 새로
만든 회귀라고 단정하지 않는다. 미확인 Keeper는 현재 health를 나중에
다시 대조해 추정하지 않는다. facts를 읽을 때의 누락이 같은 결과에 남아
갱신 실패로 이전 결과를 보여줄 때도 함께 보존된다. 익명 거절에는 가짜
Keeper ID를 만들지 않는다.

추가로 `읽힌 사실`을 현재 필터의 `목록` 수량으로 명확히 하고, 표시에서
쓰지 않는 분류 라벨 helper와 그 문자열 단언을 제거했다. 사용 안내의
원문·번역 구분, 분류 필터와 검색 설명도 현재 구현에 맞췄다.

독립 검토는 세 관점으로 나눴다. Goal·Task에서는 마지막 증거 행의 실제
`Presented`와 확인 요청의 결속, 언어 변경 중 늦은 문서 결과의 거절,
Candle 이동과 Goal별 스크롤 소유권을 읽었다. Board·Memory에서는 댓글·종결
기록·캐시·부분 관측을 읽었다. 공통 검색 검토에서 상태어 검색 결함을 찾았다.
작성하지 않은 별도 리뷰어가 통합 수정 전체를 다시 읽었고 추가 P0–P2를
찾지 못했다. 이는 로컬 에이전트의 소스 검토이며 정식 GitHub 승인이 아니다.

첫 소스 검토 단계의 검증은 OCaml 5.5.1의 변경 파일 구문 검사와 `git diff --check`다. 저장소의
고정 버전은 5.5.2이므로 구문 검사를 타입·빌드·실행 성공으로 부르지 않는다.
새 의미 검사 사례는 추가했으며 그 단계에서는 실행하지 않았다. 로컬 Dune,
CI dispatch·조회, native 재실행·설치·서버 재시작·병합은 수행하지 않았다.
[기존 A0 캡처](../evidence/four-surface-reading-20261109/README.md)는
이번 수정의 실행 증거가 아니다.

기존 [정식 변경 요청](https://github.com/jeong-sik/masc/pull/50698#pullrequestreview-5827769064)의
화면 문구·배치·행 순서 검사를 복원하라는 요구는 constitution의
`execution_protocol/build_and_ci`와 충돌한다. 해당 검사를 복원하지 않고
요청·저장 상태·선택·조회 범위를 검사하는 계약을 유지했다. 그 변경 요청을
임의로 해제하거나 다른 계정의 승인이 대체했다고 주장하지 않는다.

## 요청된 의미 검사 실행

이후 실행 요청에 따라 최소 검사만 별도로 실행했다. 첫
[Test 실행 42647821236](https://github.com/jeong-sik/masc/actions/runs/42647821236)의
실제 source는 `671cf26047fdb8a8785bff33355972b3a1f03d66`다.
`test_tui_decode` 407개는 성공했다. `test_tui_render_memory` 14개 중
새 상태어 검색을 포함한 11개가 성공했고 기존 목록 높이·분류 패널 문구와
배치 검사 3개가 실패했다. 실행 전체의 결론은 failure다.

실패한 UI 검사를 제품 배치에 맞춰 고치지 않고, 같은 suite의 검증을
선택 ID·typed 분류 필터·이전 관측과 누락 범위·원문 보존·제어문자 안전성으로
정리했다. 실패한 갱신 뒤 실제 fleet 병합의 `Some unread_summary`가 facts와
함께 Stale에 남고, 네 수량 범위가 미확인을 유지하는지도 직접 검사한다.
정리한 suite는 13개 사례이며 표시 문구·폭·행 순서를 단언하지 않는다.

그동안 공개 상위 스택이 새 main을 포함해 재배치됐다. 오래된 로컬 원격
참조의 파일 비교로 동일 소스라고 판단한 설명을 철회했다. 공개된 상위
10개 층을 보존하고 Native Stack 전체를 정렬했으며 이 층의 base는
`7175899d3af7801f489265afb42e6f4836a31f2e`다. 새 v12 health의
`Pass_pending` payload와 별도 admission 대기를 반영했다. 구체적인 대기
사유의 영어 표현과 기존 tone·admission 우선순위를 유지하면서 공통 helper에
한국어와 검색어를 더했다. 검색 검사는 대기 원인과 admission 관측도 Keeper ID로
연결한다. 초기 407개 성공을 이 새 소스의 실행 증거로 재사용하지 않는다.

이 수리를 작성하지 않은 로컬 리뷰어가 새 head와 base 사이의 전체 leaf diff와
직접 소비자를 다시 읽었다. 별도 에이전트는 자신이 작성하지 않은
pending·검색 통합을 재검토하고, 자신이 작성한 facts 병합의 동일성을 확인했다.
전체 독립 검토와 이 부분 재검토에서 추가 P0–P2는 찾지 못했다.
이 소스 판정은 상위 전체 변경의 승인이나 실행 성공을 뜻하지 않는다.

새 source `b56552704a5b1350d636449d57c1ff0d920c8adc`에 대해
[Test 실행 42652183034](https://github.com/jeong-sik/masc/actions/runs/42652183034)를
`suite=test_tui_decode,test_tui_render_memory`, `minimal=true`로 요청했다.
요청 직후 API의 실제 head를 대조했다. 완료 결과는 failure이며 Memory 13개는
모두 성공하고 decode 407개 중 406개가 성공했다. 남은 1개는 새 admission
fixture의 집계 불일치였다. 미관측 durable 행의 unread는 `null`인데 fleet
총합이 `0`이었다. SSOT의 규칙대로 fixture 총합을 `None`으로 맞추고 결과도
검사하도록 고쳤다. 제품의 엄격한 디코더와 기존 unknown→0 거절 검사는
유지했다. 이 테스트 수정은 독립 소스 검토를 거쳤다.

수정 source `f35a50b9ec9ba4d3cdd03cf0d03ea57f5924f657`에서
[Test 실행 42654972273](https://github.com/jeong-sik/masc/actions/runs/42654972273)를
decode만 `minimal=true`로 요청하고 API의 실제 head를 확인했다. 당시 상태는
in_progress였고 완료 후 API 결론은 success, runner의 407개 검사도 모두 성공했다.
`b565527…` 이후에는 `test/test_tui_decode.ml`만 바뀌어 이미
성공한 Memory 13개를 반복하지 않았다. 결과 기록은 Usage 층 위의 별도
문서 층에 두며 그 Usage 구현을 이 검사로 실행했다고 주장하지 않는다.
뒤에 추가된 Usage #50730도 함께 native rebase하고 atomic lease push했다.
독립 비교에서 재배치 전후 Usage의 전체 diff는 byte 단위로 같았으며,
그 아래 10개 공개 head도 보존했다. 이 보존 확인을 Usage의 새 승인으로
확대하지 않는다. 공개 12개 head·base와 선택한 실행 로그는
[실행 기록](../evidence/four-surface-memory-validation-20261110/README.md)에 남긴다.

Usage changelog의 자기 PR 인용 누락은 처음에 문서 층에서 `#50730`을 더해 고쳤다.
후속 리뷰에서 이 인용을 Usage 층 자체로 옮기고 상단 층을 다시 정렬했다.
제품·테스트와 앞선 실행의 source·결과 기록은 그대로 유지했다.

이 실행은 Full CI·native TUI 관측·실제 Enter
이벤트 처리·설치·서버 재시작·병합·배포 검증이 아니다.
