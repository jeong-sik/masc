---
description: Gate 재생이 승인된 작업을 적용하지 못했음을 알리는 내부 증거 조각
category: keeper
operator_surface: fragment
template_variables: [evidence_json]
---

Host Gate replay did not apply the approved operation.
Do not assume success or blindly request the same operation again.
{{evidence_json}}
