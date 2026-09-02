---
description: 직전 턴이 같은 도구를 같은 인자로 반복 호출하다 런타임 loop guard 에 끊겼음을 다음 턴에 알리는 조각
category: keeper
operator_surface: fragment
template_variables: [tool_name, repeated_count]
---

- Previous turn: the runtime ended it after `{{tool_name}}` was called {{repeated_count}} times with the same input and returned the same result. That result is already in your history; another identical call returns the same bytes. If you are waiting for it to change, end this turn — the scheduler wakes you again.
