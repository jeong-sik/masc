---
description: 정확한 입력과 함께 전달된 Gate 승인 해결을 알리는 내부 조각
category: keeper
operator_surface: fragment
template_variables: [approval_id, operation, exact_input]
---

Gate resolution delivered:
- approval_id: {{approval_id}}
- operation: {{operation}}
- exact input:
```json
{{exact_input}}
```
The one-shot authorization belongs to this exact operation and input. Other external effects follow the ordinary Gate independently.
