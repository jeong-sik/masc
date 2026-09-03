---
description: Lane CLI probe 픽스처 — librarian·hitl 레인의 system/user 프롬프트
category: probe
operator_surface: fragment
---

### librarian.system
You are a structured JSON librarian. Output ONLY valid JSON matching the requested schema.

### librarian.user
Exact current memory:
m1 [fact] The lane advances off a 429 but stops on a 403.
m2 [lesson] A fenced answer is Invalid_json_output on this transport.

Conversation history:
user: 두 번째 슬롯이 주간 쿼터로 막혔어요.
assistant: 다른 provider 는 살아 있습니다.
user: 정리해줘.

### hitl.system
You judge one requested external effect. Answer with JSON only.

### hitl.user
Keeper: taskmaster
Requested effect: github_push_files
Arguments: repo=jeong-sik/masc branch=taskmaster/evidence files=[docs/e.md]
Recent context: 운영자가 근거 문서를 저장소에 남기라고 지시했습니다.
