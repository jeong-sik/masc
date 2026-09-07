---
rfc: "0436"
title: "증거는 텍스트만이 아니라 파일이다 — binary artifact 를 해시로 못박고 judge 가 이미지로 보게 하는 채널"
status: Draft
created: 2026-09-07
updated: 2026-09-07
author: vincent
supersedes: []
superseded_by: null
related: ["0417", "0427"]
---

## 1. 문제

typed evidence 캡처가 샌드박스 백엔드를 타도록 수선된 뒤(#33792, 2026-09-07 실증),
artifact 증거는 텍스트로만 살아 있다. binary 파일은 두 층에서 막힌다.

| 층 | 지금의 동작 | 근거 |
|---|---|---|
| 캡처 | `scan_utf8`이 non-UTF-8 바이트를 `invalid_utf8`으로 typed 거부 | `workspace_verification_store.ml` reader 갈래 (#33816) |
| 판정 | judge 는 evidence items 의 content 텍스트를 JSON transport 로 받는다 — 바이트를 실을 자리가 없다 | `completion_authority_agent.ml` review_request |

운영자 요청은 명확하다: UI 작업 키퍼의 스크린샷 같은 **이미지 증거**를 제출하고
judge 가 그것을 보게 하고 싶다. 반대로 말하면, 지금 키퍼는 "버튼이 깨진 화면"을
증거로 내려면 글로 묘사하는 수밖에 없다.

### 1.1 사실

- 멀티모달 운반 계약은 이미 있다. `Keeper_multimodal_input.user_input_block` 은
  `User_image` 를 세 형태로 싣는다 — 서버가 보유한 바이트(attached), URL 참조,
  Files-API id — 하고 attachments 스토어와 agent_core 전달까지 갖춰져 있다
  (#33669, #33728). 키퍼 채팅이 쓰는 길이다.
- judge 레인의 evaluator 는 요청이 지정한다(실측 예: `ollama_cloud … deepseek-v4-flash`
  — 텍스트 모델). 이미지를 못 보는 evaluator 는 이미 존재하는 상태다.
- 캡처 상한은 `verification_evidence_max_bytes` 하나다. base64 는 4/3 로
  팽창하므로 상한 계산이 바이트 기준임을 명시해야 한다.

## 2. 목표

1. binary artifact 가 제출되면 **내용의 무결성(sha256)과 크기, 포맷**이 typed
   증거로 기록된다 — 텍스트 증거와 같은 스냅숏 안에.
2. 이미지 포맷은 judge 가 **이미지로** 받는다 — 멀티모달 계약의 `User_image(attached)`
   를 타고.
3. evaluator 가 이미지를 못 보는 모델이어도 채널은 죽지 않는다 — 참조와 해시가
   판정에 남고, 해석은 note: 가 담당한다(§4.4).

## 3. 비목표

- judge 가 이미지를 "봐서" 내리는 판정의 품질 보장 — evaluator 교체와 vision
  라우팅 정책은 운영자 영역이고 이 RFC 는 운반만 계약한다.
- audio/document 의 judge 전달. 캡처 typed 아이템은 포맷 무관히 남기지만
  judge 가 싣는 것은 이미지만 1단계로 한다(§5).
- URL/Files-API 참조 형태의 증거 — 첨부 바이트만. 참조 형태는 이 서버가 그
  내용을 보증하지 않으므로 해시 계약이 성립하지 않는다.

## 4. 설계

### 4.1 캡처 — binary 아이템

`Evidence_artifact` 의 형태를 나눈다.

```
Evidence_artifact { reference; content; bytes; truncated }        (* 텍스트, 지금 그대로 *)
Evidence_artifact_binary { reference; bytes; sha256; format }      (* 신설 *)
```

reader 결과에 `scan_utf8` 을 돌린다. valid 면 텍스트 아이템, invalid 면 바이트를
버리지 않고 binary 아이템으로 바꾼다 — sha256(Digestif), bytes(원본 크기,
상한은 원본 바이트 기준), format(확장자에서 유도, 알 수 없으면 "unknown").
truncated 는 상한에 닿은 경우 바이트 수로만 표현한다.

### 4.2 저장 — attachments

binary 아이템의 바이트는 attachments 스토어에 적재한다(`Keeper_chat_store.attachment`,
이미지 첨부가 쓰는 저장소). 스냅숏의 `content` 필드는 싣지 않는다 — 스냅숏은
증거의 **명세**이고, 바이트는 attachments 가 **본문**이다. attachment_id 를
binary 아이템에 실어 둘을 잇는다.

### 4.3 judge 전달 — User_image

review_request 조립에서, binary 아이템 중 format 이 이미지(png/jpg/gif/webp)면
`User_image(Attached …)` 블록으로 evaluator 입력에 추가한다. 그 외 binary 는
참조+해시 텍스트로만 전달한다. 텍스트 아이템은 지금처럼 content 로.

### 4.4 내려가는 길

evaluator 가 이미지 블록을 소화하지 못하는 모델이면 provider 계층의 기존
거절 경로를 탄다. 판정 요청은 죽지 않아야 한다 — completion authority 는
이미지 블록 전달 실패를 해당 아이템의 참조+해시 강등으로 처리하고 판정을
계속한다. 이 강등이 §2.3 의 하한이다.

### 4.5 상한과 예산

- 캡처 상한은 원본 바이트 기준 `verification_evidence_max_bytes` 를 그대로 쓴다.
- judge 전달 시 이미지 크기 상한은 evaluator 레인의 wire 상한
  (`Common.max_tool_result_wire_bytes` 계열)을 넘지 않게 별도 상한으로 자른다.
  넘치는 이미지는 참조+해시로 강등한다.

## 5. 단계

| 단계 | 내용 | 산출 |
|---|---|---|
| 1 | 캡처: `Evidence_artifact_binary` + sha256 + format + attachments 적재 | store PR + 테스트(바이너리 픽스처) |
| 2 | judge: 이미지 binary 아이템의 `User_image` 전달과 강등 | completion authority PR + 비(vision) evaluator 테스트 |
| 3 | 운영: 이미지 증거 태스크에 vision evaluator 지정 가이드 | docs |

단계 1만으로 (a)안의 무결성 채널이 성립한다 — 2 는 그 위의 판정 개선이고,
각각 독립 배포된다.

## 6. 대안과 거부 사유

- **base64 를 스냅숏 content 에 그대로 실는 것** — 스냅숏 JSON 이 바이트의
  4/3 팽창을 떠안고, judge 가 base64 를 텍스트로 읽는 일이 생긴다. 운반은
  attachments, 명세는 스냅숏이라는 분리를 지킨다.
- **URL 참조 증거** — 이 서버가 내용을 보증하지 않는 참조는 해시 계약이
  성립하지 않는다. 비목표로 밀어낸다.
- **judge 에게 파일 경로만 주고 다시 읽게 하는 것** — #33745 의 교훈 그대로,
  경로는 프로필마다 다른 곳을 가리킨다. 캡처 시점의 바이트와 해시가 증거다.
