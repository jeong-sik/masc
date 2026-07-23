(** Compact runtime-trust JSON + degraded snapshot row helpers,
    extracted from operator_control_snapshot.ml. *)

(* Local copies of trivial helpers to avoid sibling -> parent cycle. *)
let non_empty_trimmed_string_opt value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed


let compact_runtime_trust_cache_ttl_sec = 3.0

(* Cache key for the per-keeper runtime-trust projection.

   History:

   - Originally embedded [meta.updated_at] (ISO timestamp ticking on
     every meta refresh): 41/64 entries (65%) of the shared LRU
     belonged to this prefix, evicting hot keys (branches/workspaces/board).
     PR #19010 dropped [meta.updated_at].
   - PR #19010 retained [meta.runtime.usage.total_turns] in the key,
     reasoning that monotonic per-turn invalidation was useful.  On a
     live fleet this still produced a fresh entry per turn — a
     /dashboard/cache-stats snapshot showed 22/48 entries (45%) of the
     same prefix, every one expired.  26 keepers × N turns/min ticked
     the LRU through the same pollution pattern, just slower.
   - TTL was 1.0s, intended as the invalidation signal.  In practice
     dashboard polls every 5-7s, so the cache NEVER hit — every refresh
     paid 400-580ms for receipt file I/O per keeper.  Raising to 3.0s
     keeps data fresh (at most 3s stale) while allowing cache reuse
     between dashboard refresh cycles.  Measured impact: trust sub-op
     drops from 400-580ms (miss) to ~43ms (hit) on warm cycles.

   Identity bits the key keeps:
   - [meta.runtime.generation]: bumped on supervisor restart / takeover.
   - [meta.paused]: explicit pause/unpause toggle.

   Result: each keeper has exactly one cache slot.  Turn transitions
   are picked up via the 3s TTL refresh.  Pollution shrinks from
   N keepers × M turns_per_window to just N keepers. *)
let compact_runtime_trust_cache_key
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
  =
  Printf.sprintf
    "operator:keeper-runtime-trust:compact:v1:%s:%s:%d:%b"
    config.base_path
    meta.name
    meta.runtime.generation
    meta.paused
;;

let project_compact_runtime_trust runtime_trust =
  let member key =
    match Json_util.assoc_member_opt key runtime_trust with
    | Some v -> v
    | None -> `Null
  in
  `Assoc
    [ "disposition", member "disposition"
    ; "disposition_reason", member "disposition_reason"
    ; "operator_disposition", member "operator_disposition"
    ; "operator_disposition_reason", member "operator_disposition_reason"
    ; "needs_attention", member "needs_attention"
    ; "attention_reason", member "attention_reason"
    ; "next_human_action", member "next_human_action"
    ; "execution_summary", member "execution"
    ; "latest_terminal_reason", member "latest_terminal_reason"
    ; "latest_next_action", member "latest_next_action"
    ; "latest_causal_event", member "latest_causal_event"
    ]
;;

let compact_keeper_runtime_trust_json
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
  =
  let runtime_trust =
    Dashboard_cache.get_or_compute
      (compact_runtime_trust_cache_key ~config ~meta)
      ~ttl:compact_runtime_trust_cache_ttl_sec
      (fun () -> Keeper_runtime_trust_snapshot.summary_json ~config ~meta)
  in
  project_compact_runtime_trust runtime_trust
;;
