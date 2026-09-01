---
description: Task 계약이 요구한 증거 항목을 조립하는 내부 검증 섹션
category: verification
operator_surface: fragment
template_variables: [evidence_items]
---

<required_evidence>
task 계약은 아래 나열된 항목 전부의 뒷받침을 요구합니다. 항목마다 독립적으로
판정합니다. 검사 가능한 증거란 사용 가능하고 잘리지 않은 `[artifact:]` 내용 —
그리고 이 프롬프트에 `<live_lookup>` 블록이 있다면 그 블록이 설명하는 tool로
직접 연 것입니다. URL, 호스트 경로, commit, board 참조, 명령 주장, 서술
노트는 그 자체로는 증거가 아닙니다: 무언가를 보여 주는 게 아니라 가리킬
뿐입니다. 요구된 뒷받침이 없거나, 사용할 수 없거나, 잘렸거나,
자리표시자거나, 실증되지 않으면 REJECT 합니다.
{{evidence_items}}
</required_evidence>
