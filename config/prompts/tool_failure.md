---
description: 도구 실패 등급별 다음 수 — tool_bridge 가 분류를 골라 끼운다
category: tool
operator_surface: fragment
---
### dependency_unavailable
The dependency this tool needs did not answer. Your arguments were not judged, so the same call with other arguments fails the same way. Do other work or end the turn; it can answer on a later turn.

### operator_cancelled
An operator stopped this call. It is not re-issued. Say where it stopped in your answer.

### policy_rejection
Rejected before running. The message above names the field or permission that failed. A call with that field corrected can succeed; a missing permission does not change with different arguments.

### runtime_failure
The tool failed inside the runtime, not on your arguments. Identical arguments reproduce it unless the message says the outcome is unknown. Report it as a runtime failure in your answer.

### workflow_rejection
The current state does not admit this action; it is a rule, not a syntax problem. Read the current state first. The same call succeeds only after the state changes.

