(** Keeper_memory_os_consolidation_runtime — LLM wiring for the consolidation pass.

    Mirrors [Keeper_librarian_runtime]: the LLM call is an injectable [complete_fn]
    (default = the real provider) so the read -> prompt -> LLM -> parse -> apply ->
    write-back loop is driveable with a fake completion in tests. Reuses
    [Keeper_memory_llm_summary]'s provider/transport helpers. The structure is
    deterministic; the only judgement is the model's consolidation plan.

    This is the read/write loop only — the cadence (when to consolidate) is the caller's.
    Like the GC fiber, it stays disabled until a live shadow run validates it. *)

module Io = Keeper_memory_os_io
module Consolidation = Keeper_memory_os_consolidation

(* Same shape as [Keeper_memory_llm_summary.complete_fn]; the LLM call is
   injectable so the loop is driveable with a fake completion in tests. *)
type complete_fn = Keeper_provider_subcall.complete_fn

let user_message text : Agent_sdk.Types.message = Agent_sdk.Types.user_msg text
;;

(* The plan can list many groups over a large store, so allow more than the
   512-token summary budget. 2048 was too small for live stores: on 2026-07-20
   per-keeper fact stores reached 300-635 rows, and a grouping plan over that
   many indices does not fit in 2048 output tokens. *)
let consolidation_max_tokens = 8192

type outcome =
  | Skipped_too_few of int
  | Transport_failed of string
  | Unparseable of string
  | Empty_response
  | Invalid_structured_response of string
  | Snapshot_changed of
      { before : int
      ; current : int
      }
  | Consolidated of
      { before : int
      ; after : int
      }
  | Plan_rejected_total_deletion of { before : int }

(* Serialize only the final snapshot validation + rewrite against the per-keeper
   facts file. The provider call runs without this lock, then the locked rewrite
   validates that the fact snapshot still matches the model input
   ([Io.same_fact_snapshot]). Wraps the shared [Io.with_facts_lock] so a contended
   cycle becomes a typed [Transport_failed] rather than an escaping [Flock_timeout]
   (the lock/CAS helpers are the SSOT shared with the reconcile rewrite path). *)
let with_facts_lock ?clock ~keeper_id f =
  Io.with_facts_lock
    ?clock
    ~keeper_id
    ~on_timeout:(fun msg -> Transport_failed ("consolidation " ^ msg))
    f
;;

(* The consolidation request carries no wire [response_format]: the prompt
   states the output contract (config/prompts/keeper.librarian.memory_consolidation.md
   spells out the object, its fields, and the empty-plan reply) and
   [Consolidation.plan_of_json] is total, so a malformed reply becomes
   [Unparseable] / [Invalid_structured_response] instead of a bad write. A
   schema on top of that added no guarantee the parser did not already provide,
   only a capability branch: [validate_output_schema_request] rejects
   json_schema on every json_object-only endpoint, and the parse path never
   read a provider-side field anyway — [structured_json_of_response] extracts
   JSON from the response's visible text. *)
let provider_for_consolidation (provider_cfg : Llm_provider.Provider_config.t) =
  let max_tokens =
    match provider_cfg.max_tokens with
    | Some n when n > 0 -> Some n
    | Some _ | None -> Some consolidation_max_tokens
  in
  { provider_cfg with
    Llm_provider.Provider_config.max_tokens
  ; tool_choice = None
  ; disable_parallel_tool_use = true
    (* Mirror the librarian tuning: reasoning-capable providers (GLM live)
       otherwise spend the whole output budget on thinking and return an
       empty visible text — observed live on 2026-07-20 as 256 consecutive
       [Empty_response] outcomes while only trivial 2-fact stores
       consolidated. *)
  ; enable_thinking = Some false
  ; preserve_thinking = Some false
  ; thinking_budget = None
  ; clear_thinking = Some true
  }
  |> Keeper_structured_output_schema.without_response_format
;;

module For_testing = struct
  let provider_for_consolidation = provider_for_consolidation
end

(* Request tuning is a function of the provider config alone — never of the
   keeper — so it is resolved once per consolidation tick, not once per keeper.
   No Result: with no schema requested there is nothing left that can reject
   the config. *)
let resolve_provider_for_consolidation = provider_for_consolidation
;;

let messages_for_consolidation facts =
  let numbered = Consolidation.render_numbered_facts facts in
  match
    Prompt_registry.render_prompt_template
      Keeper_prompt_names.librarian_memory_consolidation
      [ "numbered_facts", numbered ]
  with
  | Error msg -> Error msg
  | Ok user ->
    let user = String.trim user in
    if String.equal user ""
    then Error "consolidation prompt rendered empty"
    else Ok [ user_message user ]
;;

let rewrite_if_snapshot_current ?clock ~keeper_id ~facts ~survivors ~before ~after () =
  with_facts_lock ?clock ~keeper_id (fun () ->
    match Io.read_facts_all_strict ~keeper_id with
    | Error msg ->
      Unparseable ("consolidation fact store changed before rewrite: " ^ msg)
    | Ok current ->
      if not (Io.same_fact_snapshot facts current)
      then Snapshot_changed { before; current = List.length current }
      else (
        Io.rewrite_facts_atomically ~keeper_id survivors;
        Consolidated { before; after }))
;;

let invalid_structured_response reason =
  Invalid_structured_response
    ("consolidation provider returned invalid structured response: "
     ^ Consolidation.output_rejection_reason_to_string reason)
;;

let invalid_structured_response_detail detail =
  Invalid_structured_response
    ("consolidation provider returned invalid structured response: " ^ detail)
;;

(* Read [keeper_id]'s facts, ask the model for a consolidation plan, apply it, and
   (unless [dry_run]) rewrite the store atomically. Returns what happened without
   raising for the expected failure modes (too few facts, transport error,
   unparseable plan) so a caller fiber stays alive.

   [provider_cfg] must already be tier-resolved via
   [resolve_provider_for_consolidation]; this function no longer re-applies the
   output contract per keeper (the tier is keeper-independent). *)
let consolidate_keeper
      ?complete
      ?clock
      ?(dry_run = false)
      ~sw
      ~net
      ~runtime_id
      ~provider_cfg
      ~now
      ~keeper_id
      ()
  =
  match Io.read_facts_all_strict ~keeper_id with
  | Error msg -> Unparseable ("consolidation fact store read failed: " ^ msg)
  | Ok facts ->
    let before = List.length facts in
    if before = 0
    then Skipped_too_few before
    else
      match messages_for_consolidation facts with
      | Error msg -> Unparseable msg
      | Ok messages ->
        (match
           Keeper_provider_subcall.complete ?override:complete ~sw ~net ?clock
             ~config:provider_cfg ~messages ()
         with
         | Error _ -> Transport_failed "consolidation provider transport error"
         | Ok response ->
           if String.trim (Agent_sdk_response.text_of_response response) = ""
           then Empty_response
           else
             (match
                Agent_sdk_response.structured_json_of_response
                  ~schema_name:"keeper_memory_consolidation_plan"
                  response
              with
              | Error detail -> invalid_structured_response_detail detail
              | Ok (`Assoc _ as json) ->
                let plan = Consolidation.plan_of_json json in
                let survivors, stats = Consolidation.apply_plan ~now ~facts plan in
                (* Only the gate mismatches mean the judge and the apply gate
                   disagreed — with the gate fields rendered into the prompt
                   that should be rare, so it is loud. The sum deliberately
                   excludes [rejected_too_few_members]; see
                   [Consolidation.gate_rejection_count]. *)
                let gate_rejected_groups =
                  Consolidation.gate_rejection_count stats
                in
                if gate_rejected_groups > 0
                then (
                  Log.Keeper.warn
                    "memory_os_keeper_consolidation rejected %d group(s) at the merge gate keeper=%s: kind_mismatch=%d valid_until_mismatch=%d (merged=%d dropped=%d too_few_members=%d)"
                    gate_rejected_groups
                    keeper_id
                    stats.rejected_kind_mismatch
                    stats.rejected_valid_until_mismatch
                    stats.merged_groups
                    stats.dropped
                    stats.rejected_too_few_members;
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string MemoryOsConsolidationGroupRejected)
                    ~labels:[ "keeper", keeper_id ]
                    ())
                else if stats.rejected_too_few_members > 0
                then
                  Log.Keeper.info
                    "memory_os_keeper_consolidation skipped %d group(s) below two free members keeper=%s (merged=%d dropped=%d)"
                    stats.rejected_too_few_members
                    keeper_id
                    stats.merged_groups
                    stats.dropped;
                let after = List.length survivors in
                (* [before > 0] is guaranteed by the [Skipped_too_few] guard above,
                   so [after = 0] here means the plan asked to erase the store. A
                   plan that keeps nothing is treated as a malformed response, not
                   as judgement: the store is the keeper's only durable memory and
                   [rewrite_facts_atomically] renames over the sole copy, so the
                   rows are unrecoverable. A truncated response that loses its
                   [groups] array while retaining [drop_indices] produces exactly
                   this shape. Only total erasure is refused — a large deletion
                   over a mostly redundant store is a legitimate outcome, so no
                   ratio or floor is imposed on [after > 0]. *)
                if after = 0
                then Plan_rejected_total_deletion { before }
                else if dry_run
                then Consolidated { before; after }
                else
                  rewrite_if_snapshot_current
                    ?clock
                    ~keeper_id
                    ~facts
                    ~survivors
                    ~before
                    ~after
                    ()
              | Ok _ -> invalid_structured_response Consolidation.Non_object_json)
        )
;;
