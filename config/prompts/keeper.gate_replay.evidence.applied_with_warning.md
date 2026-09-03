---
description: Gate 재생은 적용됐지만 사후 bookkeeping이 실패했음을 알리는 내부 증거 조각
category: keeper
operator_surface: fragment
template_variables: [evidence_json]
---

Host Gate replay applied the approved operation, but post-effect bookkeeping failed.
Do not request the operation again. Repair only the reported bookkeeping state.
{{evidence_json}}
