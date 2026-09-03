---
description: Gate 재생이 적용 여부를 증명할 수 없음을 알리는 내부 증거 조각
category: keeper
operator_surface: fragment
template_variables: [evidence_json]
---

Host Gate replay cannot prove whether the approved operation applied.
It will not be replayed. Inspect the target before requesting any compensating operation.
{{evidence_json}}
