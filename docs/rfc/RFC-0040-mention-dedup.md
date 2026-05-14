# RFC 0040 — Mention dedup at sender (broadcast-time)

> Note: drafted as RFC-0036.v2 in loop-iter-8 (2026-05-07).  Renumbered
> to RFC-0040 at PR time because RFC-0036 was already taken by
> RFC-0036-oas-cognitive-mapping (PR #13915).  Content unchanged from
> the iter-8 draft.

- **Status**: Draft (loop-iter-8, 2026-05-07) — *replaces* iter-6/7 sketch
- **Author**: Vincent + Claude (auto-mode loop)
- **Resolves Board Issues**: "24+ mention spam to nick0cave" (taskmaster), "Tripartite Coordination Breakdown — same task re-mention" (sangsu/imseonghan)
- **Sister**: RFC-0035 (memory write — orthogonal complement that lets keepers act on mentions)

---

## 1. iter-6/7 sketch correction (Narrative cascade)

Earlier iter-6 sketch + iter-7 *correction* both assumed:
> "Mention dispatch happens at broadcast time; resolve_targets filters recipient set."

**Verified (iter-8 grep, iter-9 cross-check 정정)**: `Mention.resolve_targets` has **0 callers in `lib/` production code** (test/docs는 별도). 정확히는:
- `lib/coord/mention.ml:110` 정의 + `lib/coord/mention.mli:32` export
- `docs/spec/03-room-coordination.md:437`에서 *공식 API 명시* — design 의도 존재
- `test/test_mention.ml`, `test/test_mention_coverage.ml`에 6+ test
- **lib/ 의 production caller는 0** — 의도된 API이나 미사용 (intended-but-unused infra)

Mention model is actually:

| Step | Where | Action |
|---|---|---|
| Sender writes content | `Coord_broadcast.broadcast` | Persist to disk, emit hook |
| Sender extracts mention | `coord_broadcast.ml:122 Mention.extract content` | parse `@target` token, *informational only* |
| Recipient pulls | `keeper_prompt.ml:16 Mention.any_mentioned ~targets:[my_name] content` | Each keeper checks own name in board on its turn |
| Recipient handles | `keeper_exec_context.ml:418`, `keeper_memory_policy.ml:83` | direct_mention boolean → prompt injection / memory tagging |

즉 **pull model**. Keeper가 자기 board를 읽고 mention 검색. iter-6 sketch의 *push-time dispatch filter* 가정은 **틀린 design**.

이는 R3 (caller 전체 grep + 1-2 사이트 본문 read) 미적용 사례 — `resolve_targets`만 보고 *export = used*로 가정.

## 2. Motivation (정정)

24-mention spam 흐름:
1. taskmaster가 task-037 stale 의심 → broadcast 호출 (with `@nick0cave` in content)
2. content 디스크 persistence + hook (recipient 결정 안 함)
3. nick0cave가 자기 turn에 board 읽고 `Mention.any_mentioned ~targets:["nick0cave"]` → True
4. nick0cave가 응답할 capability 없음 (P4 write-path 부재) → board에 또 글 쓰거나 무응답
5. taskmaster가 *같은 stale*에 또 broadcast → 1로 돌아감

매 cycle 발생 → 24회 누적.

근본 원인 두 축:
- **A. 발신자 dedup 부재**: taskmaster가 같은 (target, topic) 발신을 N분 내 반복 차단 안 함.
- **B. 수신자 acknowledgement 부재**: nick0cave가 mention 받았다는 신호를 발신자에게 보낼 capability 없음 (P4 RFC-0035 미해결 시).

본 RFC는 **A**만 다룸. B는 RFC-0035로 별도.

## 3. Non-Goals

- pull model 자체 변경 — 그대로.
- recipient 측 mention 처리 변경 — 그대로.
- Mention.extract / any_mentioned API 변경 — 그대로.
- A2A / direct delivery 도입 — 별도.

## 4. Design

### 4.1 발신자 측 dedup (sender-side)

`lib/coord/coord_broadcast.ml:122` `Mention.extract content` 직후, mention이 `Some target`이면 *최근 N분 내 같은 (from_agent, target, topic_hash) 발신 여부* 검사.

```ocaml
(* lib/coord/coord_broadcast.ml — 변경 후 *)
let mention = Mention.extract content in
let dedup_skip =
  match mention with
  | Some target ->
    Mention_dedup.should_skip
      ~from_agent ~target
      ~content_hash:(content_topic_hash content)
      ~now:(Time_compat.now ())
  | None -> false
in
if dedup_skip then begin
  Log.Misc.info
    "[mention-dedup] skipped duplicate mention from %s to %s within window"
    from_agent (Option.value ~default:"<none>" mention);
  Coord_hooks.coord_broadcast_observed_fn ~msg_type:"dedup_skipped" ~elapsed_s:0.0;
  Result.Ok "dedup_skipped"
end else
  (* 기존 흐름 그대로 *)
  ...
```

### 4.2 신규 모듈 `lib/coord/mention_dedup.{ml,mli}`

```ocaml
type t (* abstract; module-level singleton via Atomic / Mutex *)

(** Default 5min window; configurable via env MASC_MENTION_DEDUP_TTL_S. *)
val default_ttl_seconds : float

val should_skip :
  from_agent:string ->
  target:string ->
  content_hash:string ->
  now:float ->
  bool

(** Test-only reset hook. *)
val reset_for_test : unit -> unit

(** Emit Prometheus metric on every check. *)
(* internal: metric_mention_dedup_decisions_total{outcome} *)
```

**구현 내부**:
- `Hashtbl` keyed by `(from_agent, target, content_hash)` → last_seen timestamp
- `should_skip` 호출 시 entry 있고 `now - last_seen < ttl` → true (skip), 아니면 entry 갱신 + return false
- Hashtbl size > 1000 시 LRU prune (낮은 priority — 확장 시점 별도 PR)
- Server restart 시 fresh — *의도된 동작* (restart는 1회 mention OK)

### 4.3 `content_topic_hash`

같은 topic의 동일 변종 문구도 dedup하기 위해 hash key는 *문장 단위가 아닌 topic*. 단순화 — 처음에는 *content 그대로 SHA1*로 시작 (variant detection 미적용). 발견 시 `Coord_topic.normalize_for_dedup`(별도 RFC) 추가.

```ocaml
let content_topic_hash content =
  Digest.string (String.lowercase_ascii (String.trim content)) |> Digest.to_hex
```

trade-off: *exact-match dedup*. taskmaster가 *조금 다르게 같은 의미*를 여러 번 보내면 모두 통과. 시작점 conservative.

### 4.4 Bypass 옵션

명시적 *force broadcast* 필요한 caller (예: incident response)는 `?bypass_dedup:bool` 추가:
```ocaml
val broadcast :
  ?trace_context:... ->
  ?msg_type:string ->
  ?task_cache_invariant_checked:bool ->
  ?bypass_dedup:bool ->          (* 신규 *)
  config -> from_agent:string -> content:string -> result
```
default `false`. Keeper code는 default. system-level alert은 `~bypass_dedup:true`.

## 5. Migration

### 5.1 영향 범위

8개 production broadcast 사이트 전부 자동으로 dedup 가드 통과:
- `lib/orchestrator.ml:120` system broadcast
- `lib/coord/coord_lifecycle.ml:108, 178, 247` (agent join/state/system)
- `lib/coord/coord_task_create.ml:236` task create alert
- `lib/coord/coord_eio.ml:588` (eio variant — 별도 함수, dedup 적용 여부 확인 필요)
- `lib/grpc/masc_grpc_client.ml:77` grpc broadcast (별도 path)

eio variant + grpc는 별도 stack — 본 RFC의 dedup이 *coord_broadcast.ml:64 broadcast*만 거치는 caller에만 적용. eio/grpc 계열 caller는 별도 fix.

### 5.2 회귀 테스트

`test/test_mention_dedup.ml` (신규):
- `test_dedup_skips_within_window` — 같은 from/target/content 5초 간격 두 번 → 두 번째 dedup_skipped
- `test_dedup_clears_after_ttl` — ttl 초과 후 동일 broadcast 통과
- `test_dedup_distinguishes_targets` — 같은 from, 다른 target → 둘 다 통과
- `test_dedup_distinguishes_content` — 같은 from/target, 다른 content_hash → 둘 다 통과
- `test_bypass_dedup_force` — `~bypass_dedup:true` → ttl 내 동일도 통과
- `test_dedup_no_target` — mention=None → dedup 미적용 (목적은 *mention 발신 dedup*)

## 6. Risks

- **Legitimate retry**: keeper가 같은 task에 의해 정상적으로 다시 mention 필요 (실제 새 정보 추가) → exact-match SHA1이라 *content 변화 시 통과*. 운영 관찰로 false positive 감지.
- **Cross-server inconsistency**: server restart 시 dedup state 사라짐. *의도된*. 운영자 명시 fault tolerance.
- **Hashtbl memory growth**: 1000+ entries 후 LRU prune 미구현. 일주일 동안 unique mention pair 수가 1000+ 이면 OOM 가능 — 별도 RFC.
- **eio/grpc broadcast bypass**: 본 RFC의 dedup이 그쪽엔 적용 안 됨. 24-mention spam이 그쪽으로 들어왔다면 본 RFC는 부분 fix.

## 7. Implementation Plan

| 단계 | 산출물 | LOC |
|---|---|---|
| S1 | `lib/coord/mention_dedup.{ml,mli}` 신설 | ~80 |
| S2 | `coord_broadcast.ml:122` 직후 dedup 호출 | ~10 |
| S3 | `~bypass_dedup` 옵션 추가 + 시그니처 변경 | ~15 |
| S4 | Prometheus counter `metric_mention_dedup_decisions_total{outcome}` | ~10 |
| S5 | 회귀 테스트 6건 | ~120 |
| S6 | env `MASC_MENTION_DEDUP_TTL_S` 통합 | ~5 |
| S7 | dune build + test green | — |
| S8 | Draft PR + RFC 인용 | — |

총 **~+240 LOC**.

## 8. Verification

### 코드 verification
- `scripts/dune-local.sh build`
- 신규 + 기존 회귀 테스트 모두 green

### 운영 verification
- 배포 24시간 후 `metric_mention_dedup_decisions_total{outcome="dedup_skipped"}` non-zero
- nick0cave류 keeper의 인바운드 mention 카운트가 *기존 대비 감소* (board에서 정성적 측정)
- false positive 사례 (legitimate retry 차단) 발견 시 별도 fix

## 9. Open Questions

1. eio variant `lib/coord/coord_eio.ml:588 broadcast`가 main `coord_broadcast.broadcast`를 호출하는지, 별도 path인지 확인 미수행. iter-9 grep.
2. grpc broadcast (`lib/grpc/masc_grpc_client.ml:77`)는 본 dedup 미적용 — *분리 RFC 또는 grpc client 측 dedup* 필요.
3. dedup state file로 persist 옵션 추후 추가 가능성 (현재 RAM only).

## 10. Self-skepticism

- §4.1 broadcast 본문 변경 sketch는 *현 broadcast.ml:64 `result` 반환 형식*과 일치 가정. 실제 함수 sig 확인은 위에서 수행했으나 return type은 미확인 — `Result.Ok "dedup_skipped"` 가 적합한지 PR 작업 중 정정 가능.
- §4.3 SHA1 hash는 *exact-match*. taskmaster가 *날짜/timestamp 포함 변종 발신* 패턴이라면 dedup 통과 → 실효성 낮을 수 있음. iter-9에서 board 24-mention 사례의 *실제 content variation*을 dump해서 확인.
- §5.1 eio/grpc broadcast가 같은 dedup 거치는지 미확인 — Open Question 1.
- iter-6/7 sketch의 design 방향이 *틀렸다*는 발견은 *meta-protocol R3 적용 안 한 결과*. 본 RFC가 R1~R6 적용 사례.

## 11. References

- iter-2 §2.P5 (initial framing)
- iter-5 §2 (P4↔P5 통합)
- iter-6 §3 (sketch — *틀린 design 방향*)
- iter-7 §3 (sketch 보강 — *부분 정정만 한 narrative cascade*)
- iter-8 §1 (본 RFC — pull model 발견 후 정정)
- 코드: `lib/coord/coord_broadcast.ml:64,122`, `lib/coord/mention.ml:121` (`resolve_targets`, 0 callers), `lib/keeper/keeper_prompt.ml:16`, `lib/keeper/keeper_exec_context.ml:418`, `lib/keeper/keeper_memory_policy.ml:83`
- Memory: `feedback_keeper_hallucinated_audit_cascade`, `feedback_rfc_section_1_4_caller_context_unverified`
