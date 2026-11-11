# 외부 rebase와 댓글 수리의 통합

첫 push는 원격 head가 먼저 바뀌어 두 branch 모두 거절됐습니다. 기존 head를 강제로 덮지 않았습니다. 원격의 실제 구현 base는 `ba04b7a80a107d2415c99eeac6ed5cf630fa106e`이고, 당시 REST의 main base는 별도로 앞으로 이동한 값입니다.

원격 production 46경로는 이전 공개 소스와 같았습니다. companion 14경로 중 `test/dune`만 달랐고, 무관한 오래된 주석 한 구절을 지운 변경이었습니다. 그 외부 rebase를 채택한 뒤 댓글 수리만 재적용하고 `gh stack rebase --no-trunk`로 두 층을 다시 연결했습니다.

현재 production은 `c7032f0ca2f8b36d48197e65d625e59170d785e4`, evidence-only addendum 전 source는 `a470f72ee00459abeca82b9d9fa2ec1b4201ff1f`입니다. [restack 기록](restack.json)은 원래 캡처의 40개 parse 입력 해시가 모두 같고 전체 Dashboard tree와 해당 authority/의존 영역이 바뀌지 않았음을 대조합니다. 검사 실행을 반복하지 않았으며, 이 ancestry 변경을 새로운 타입·backend 실행 결과로 부르지 않습니다.

[원래 수리 기록](README.md)과 세 bundle의 캡처·manifest는 그대로 보존했습니다. 이번 addendum 이후 최종 commit은 이 두 설명 파일만 더합니다.
