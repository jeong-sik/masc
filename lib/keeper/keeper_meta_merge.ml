type t = latest:Keeper_meta_contract.keeper_meta -> caller:Keeper_meta_contract.keeper_meta -> Keeper_meta_contract.keeper_meta

let caller_wins ~(latest : Keeper_meta_contract.keeper_meta) ~(caller : Keeper_meta_contract.keeper_meta) =
  { caller with meta_version = latest.meta_version }

(* RFC-0225 §3.2: cumulative usage counters never regress on a CAS retry.
   A caller that lost the race accumulated its turn onto a stale snapshot;
   taking the caller's value verbatim regressed total_turns (385→370,
   2026-06-10) and caused keeper_turn_id reuse. [max] keeps the counters
   monotonic — the losing writer's increment may be absorbed, which
   undercounts by one turn but never rewinds. last_* observations stay
   with the caller (they describe the turn that just finished). *)
let monotonic_usage_counters ~(latest : Keeper_meta_contract.keeper_meta) ~(caller : Keeper_meta_contract.keeper_meta) =
  let lu = latest.runtime.usage in
  let cu = caller.runtime.usage in
  let usage =
    { cu with
      total_turns = max cu.total_turns lu.total_turns
    ; total_input_tokens = max cu.total_input_tokens lu.total_input_tokens
    ; total_output_tokens = max cu.total_output_tokens lu.total_output_tokens
    ; total_tokens = max cu.total_tokens lu.total_tokens
    ; total_cost_usd = Float.max cu.total_cost_usd lu.total_cost_usd
    }
  in
  { caller with
    meta_version = latest.meta_version
  ; runtime = { caller.runtime with usage }
  }

let is_operator_pause (meta : Keeper_meta_contract.keeper_meta) =
  meta.paused
  && Option.is_none meta.auto_resume_after_sec
  && Option.is_none meta.runtime.last_blocker

let preserve_operator_pause_from_disk
      ~(latest : Keeper_meta_contract.keeper_meta)
      ~(caller : Keeper_meta_contract.keeper_meta)
  =
  let merged = monotonic_usage_counters ~latest ~caller in
  if is_operator_pause latest
  then
    {
      merged with
      paused = true;
      (* [latched_reason] is the typed companion to [paused]; preserve it
         from disk for the same reason [paused = true] is preserved. A
         heartbeat writer that raced in with a stale [latched_reason = None]
         must not erase the reason a pause site recorded on disk. *)
      latched_reason = latest.latched_reason;
      auto_resume_after_sec = None;
      runtime = { merged.runtime with last_blocker = None };
    }
  else merged

let heartbeat_fields_from_disk = preserve_operator_pause_from_disk
