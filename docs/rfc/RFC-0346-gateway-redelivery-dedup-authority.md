# RFC-0346 — Gateway redelivery dedup: transcript single-authority, attention as wake-hint

- Status: Draft
- Updated: 2026-07-20
- Author: vincent (drafted by Claude Opus 4.8)
- Related: #25288 (gateway redelivery NON-PASS), RFC-0344 (durable boundary enforcement 계열)
- Supersedes: #25288의 attention-layer dedup 접근

## 0. Summary

Slack/Discord gateway 재전송(redelivery)이 **두 개의 독립적·비원자 durable layer로, 서로 다른 identity로 dedup**된다. 이 RFC는 **transcript를 유일한 dedup authority로 확정**하고 attention layer를 wake-hint로 강등한다. 조사 결과 connector event identity가 이미 transcript의 delivery_key(`Queue_receipts`)에 도달하므로, **새 스키마 variant는 불필요**하다 — 변경은 layer 책임 재정의와 배선이다.

## 1. Problem (code-verified 2026-07-20)

재전송 dedup이 두 layer에서, 다른 key로 일어난다:

| Layer | 위치 | key | 범위 | 정확성 |
|-------|------|-----|------|--------|
| **Transcript** | `keeper_chat_store.ml append_user_message_once → append_line_once → find_provenance` (:656-717) | `delivery_key = Queue_receipts(slack-msg-<ts>/discord-msg-<message_id>)` | **unbounded whole-file scan**, file-locked | 정확 (재전송 append 멱등) |
| **Attention** | `keeper_external_attention.ml record` (:511-518) | `event_id = SHA256(dedupe_key)` | **tail 64KiB** (`dedup_window_bytes`, :31) | 약함 (window 밖 재분류 Fresh) |

- **P1b (실제 결함)**: attention record가 64KiB window 밖으로 밀린 뒤 재전송되면 `record`가 `Fresh`(`Recorded`)로 재분류 → **중복 attention item → 중복 turn wake**. transcript는 append를 정확히 dedup하지만, attention이 별도 identity·좁은 window로 authority인 척한다.
- **P1a (정정됨)**: memory 진단은 "dedup이 attention에 gated → 크래시 시 skip → user-line 유실"이었으나, 조사 결과 `handle_inbound`(slack :313 / discord :322)는 attention `Recorded|Duplicate`에 **gated되지 않고 무조건 실행**된다 → `append_user_message_once`가 재실행되고 whole-file scan이 transcript를 정확히 dedup한다. **transcript 경로에는 유실이 없다.** 남는 divergence는 attention의 중복 wake(P1b)다.
- **근본**: 두 layer가 다른 identity로 dedup하는 구조 자체. attention layer(event_id, 64KiB)가 end-to-end dedup authority일 수 없다 — 부분·좁은 window다.

## 2. Non-goals

- delivery_key 합타입에 `Connector_event` variant를 추가하지 않는다. connector event(slack ts / discord message_id)는 **이미** `Receipt_id.of_request_id`(exact id, no hash)를 거쳐 `Queue_receipts`로 transcript에 도달한다(`gate_keeper_backend.ml:488-505`). 스키마 확장은 불필요한 blast radius(8파일)다.
- attention layer의 64KiB tail-scan을 whole-file로 확대하지 않는다(원 설계가 Discord hot-path O(N²)를 피하려 한 이유가 유효). attention이 dedup authority가 아니게 되면 window 크기는 무해해진다.

## 3. Design

### 3.1 Transcript = single dedup authority (이미 성립, 명시화)

`append_user_message_once`의 반환 `Appended | Already_present`가 재전송 판정의 유일 권위다. connector idempotency key가 `Queue_receipts`로 전달되고 whole-file file-locked scan이 멱등을 보장하므로, 크기·window와 무관하게 정확하다. 이 계약을 mli 주석으로 명문화한다.

### 3.2 Attention = wake-hint 강등

`Keeper_external_attention.record`의 `Recorded|Duplicate`는 **wake 억제 힌트**일 뿐 dedup authority가 아니다. 중복 turn wake 방지는 attention이 아니라 **transcript 결과**로 결정한다:

- `handle_inbound` 경로에서 `append_user_message_once` 결과가 `Already_present`이면 **새 turn을 enqueue/wake하지 않는다**(기존 turn이 이미 처리 중이거나 처리됨). `Appended`일 때만 wake.
- 이로써 attention이 64KiB gap으로 `Fresh` 오분류해도, transcript가 `Already_present`를 반환하면 중복 turn이 생기지 않는다 — window 크기가 correctness에 영향을 주지 않는다.

### 3.3 크래시 윈도우 (P1a) 무해화

attention write(step 1)와 transcript/queue write(step 2) 사이 크래시:
- 재전송 시 `handle_inbound`가 무조건 실행 → `append_user_message_once` whole-file scan → transcript에 없으면 `Appended`(유실 복구), 있으면 `Already_present`(중복 방지).
- attention record가 orphan으로 남아도(step 1만 성공), transcript가 authority이므로 무해. 필요 시 attention orphan은 다음 record에서 정리(별도, non-blocking).

## 4. Crash-safety 논증

- **append 멱등**: `append_line_once`는 `update_private_file_durable_locked_result`(file-lock read-modify-write) 하에 whole-file provenance scan → 정확히 한 번 append. 동시/재전송이 lock으로 직렬화되고 scan이 중복을 잡는다.
- **event_id/idempotency stability (조사 확인)**: slack `X-Slack-Retry`는 동일 `ts` 재사용, discord `message_id`는 webhook payload에서 안정. 둘 다 `slack-msg-<ts>`/`discord-msg-<message_id>`로 `Queue_receipts`에 도달(byte-identical across redeliveries). 이 stability가 3.1의 유일 load-bearing 가정이며 코드로 확인됨.
- attention gap은 wake 중복만 유발했고, 3.2로 transcript-gated wake가 되면 그것도 사라진다.

## 5. Additive compat

스키마 변경 없음(variant 미추가) → 기존 durable row(`Direct_request|Queue_receipts`) 역직렬화 불변. RFC-0344 hard-cut 교훈이 여기선 자명하게 충족(변경이 wire schema를 안 건드림).

## 6. Blast radius

- `keeper_chat_store.mli`: `append_once_result` 계약을 "single dedup authority"로 주석 명문화.
- `server_slack_in_process_gateway.ml` / `server_discord_in_process_gateway.ml`: `handle_inbound` 후 wake/enqueue를 `append_user_message_once` 결과(`Appended` vs `Already_present`)에 gate. (현재 무조건 wake → transcript-gated wake)
- `gate_keeper_backend.ml accept_connector`: `append_user_message_once` 결과를 호출자에 반환하도록 배선(이미 append하나 결과를 wake 판정에 안 씀).
- test: 64KiB-gap 재전송이 중복 turn을 만들지 않음(회귀), 크래시-후-재전송이 유실 없이 정확히 1 append.

## 7. 대안 기각

- **Connector_event variant 추가(memory 방향)**: connector event가 이미 Queue_receipts로 도달하므로 중복. 두 개념(direct/queue vs connector)을 스키마로 늘리는 건 불필요한 blast radius. **기각**.
- **Direct_request에 connector event 우겨넣기**: 두 개념 압축 안티패턴(CLAUDE.md). **기각**.
- **attention 64KiB → whole-file 확대**: Discord hot-path O(N²) 재도입. attention이 authority가 아니게 되면 불필요. **기각**.

## 8. Acceptance

- 회귀: attention record가 64KiB 밖으로 밀린 뒤 동일 slack/discord 재전송 → 중복 turn 0, transcript append 1(`Already_present`).
- 크래시: attention record 후 transcript append 전 크래시 → 재전송 시 transcript append 정확히 1(유실 0).
- `append_user_message_once` 멱등 property test(동일 delivery_key N회 → 1 append, N-1 `Already_present`).
- TLA(선택): `TranscriptSingleAuthority` — attention state와 무관하게 (재전송 → transcript append ≤ 1) invariant.
