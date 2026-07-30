(** Keeper_memory_os_consolidation_runtime — LLM wiring for the consolidation pass.

    Mirrors [Keeper_librarian_runtime]: the LLM call is an injectable [complete_fn]
    (default = the real provider) so the read -> prompt -> LLM -> parse -> apply ->
    write-back loop is driveable with a fake completion in tests. The structure
    is deterministic; the only judgement is the model's consolidation plan.

    This is the read/write loop only — the cadence (when to consolidate) is the caller's.
    Like the GC fiber, it stays disabled until a live shadow run validates it. *)

module Io = Keeper_memory_os_io
module Consolidation = Keeper_memory_os_consolidation

(* The LLM call is injectable so the loop is driveable with a fake completion
   in tests. *)
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
  | Provider_config_invalid of Runtime.request_body_cap_error
  | Provider_transport_failed of string
  | Transport_failed of string
  | Unparseable of string
  | Empty_response
  | Invalid_structured_response of string
  | Snapshot_changed of
      { before : int
      ; current : int
      }
  | Eligibility_changed of
      { before : int
      ; newly_expired : int
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
   read a provider-side field anyway —
   [Agent_sdk.Structured.response_json_extractor] extracts JSON from the
   response's visible text. *)
let provider_for_consolidation (provider_cfg : Llm_provider.Provider_config.t) =
  let max_tokens =
    match provider_cfg.max_tokens with
    | Some n when n > 0 -> Some n
    | Some _ | None -> Some consolidation_max_tokens
  in
  Keeper_structured_output_schema.for_deterministic_subcall ~max_tokens provider_cfg
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

let rewrite_if_snapshot_current
      ?clock
      ~fresh_now
      ~keeper_id
      ~facts
      ~plan_facts
      ~survivors
      ~before
      ~after
      ()
  =
  with_facts_lock ?clock ~keeper_id (fun () ->
    match Io.read_facts_all_strict ~keeper_id with
    | Error msg ->
      Unparseable ("consolidation fact store changed before rewrite: " ^ msg)
    | Ok current ->
      if not (Io.same_fact_snapshot facts current)
      then Snapshot_changed { before; current = List.length current }
      else
        let _, newly_expired =
          Keeper_memory_os_types.partition_expired ~now:(fresh_now ()) plan_facts
        in
        if newly_expired <> []
        then Eligibility_changed { before; newly_expired = List.length newly_expired }
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
      ?(fresh_now = Time_compat.now)
      ~sw
      ~net
      ~runtime_id
      ~provider_cfg
      ~now
      ~keeper_id
      ()
  =
  match Runtime.validate_request_body_cap ~runtime_id provider_cfg with
  | Error error -> Provider_config_invalid error
  | Ok _ ->
    match Io.read_facts_all_strict ~keeper_id with
    | Error msg -> Unparseable ("consolidation fact store read failed: " ^ msg)
    | Ok facts ->
      let before = List.length facts in
      (* Expiry GC runs on a coarser cadence than this pass, so rows past their
         producer-declared horizon are routinely still on disk. They are held out
         of the plan entirely rather than filtered inside the merge: a dead row
         must neither drag a live member's horizon into the past (the merged row
         would be born expired, and the next GC tick would delete knowledge GC
         would otherwise have kept) nor have its own volatility erased by merging
         into a durable row. Both failures come from mixing the two populations,
         so they are not mixed. Expiry stays GC's decision — the untouched rows
         are written back unchanged, and the snapshot CAS still compares the
         whole store. *)
      let live, expired = Keeper_memory_os_types.partition_expired ~now facts in
      if live = []
      then Skipped_too_few before
      else
        match messages_for_consolidation live with
        | Error msg -> Unparseable msg
        | Ok messages ->
          (match
           Keeper_provider_subcall.complete ?override:complete ~sw ~net ?clock
             ~config:provider_cfg ~messages ()
         with
         | Error error ->
           let detail = Provider_http_error.to_message error in
           if Runtime_attempt_fsm.should_try_next error
           then Provider_transport_failed detail
           else Transport_failed detail
         | Ok response ->
           if String.trim (Agent_sdk_response.text_of_response response) = ""
           then Empty_response
           else
             (match
                (Agent_sdk.Structured.response_json_extractor ()) response
              with
              | Error detail -> invalid_structured_response_detail detail
              | Ok (`Assoc _ as json) ->
                let plan = Consolidation.plan_of_json json in
                (* The maintenance caller captures [now] once before processing
                   keepers serially. A provider call can therefore outlive a
                   member's declared horizon. Recheck the exact model input
                   before interpreting its indices: repartitioning and applying
                   old indices to a shorter list would target different facts,
                   while merging an expired member can create an already-expired
                   row that the next GC removes together with durable knowledge.
                   A stale temporal plan is retried on the next tick instead of
                   being remapped. *)
                let plan_now = fresh_now () in
                let _, newly_expired =
                  Keeper_memory_os_types.partition_expired ~now:plan_now live
                in
                if newly_expired <> []
                then
                  Eligibility_changed
                    { before; newly_expired = List.length newly_expired }
                else (
                  (* Indices in the plan address [live], the list the judge was
                     shown. [expired] rejoins afterwards, untouched. *)
                  let live_survivors, stats =
                    Consolidation.apply_plan ~now:plan_now ~facts:live plan
                  in
                  let survivors = live_survivors @ expired in
                  if stats.rejected_too_few_members > 0
                  then
                    Log.Keeper.info
                      "memory_os_keeper_consolidation skipped %d group(s) below two free members keeper=%s (merged=%d dropped=%d)"
                      stats.rejected_too_few_members
                      keeper_id
                      stats.merged_groups
                      stats.dropped;
                  let after = List.length survivors in
                  (* [live] is non-empty by the [Skipped_too_few] guard above. A
                     plan that retains no live survivor has erased every fact the
                     judge was allowed to act on. Expired rows rejoined above must
                     not mask that loss: they are ineligible for recall and the
                     next GC tick can remove them, leaving no usable memory. A
                     plan that keeps no live fact is treated as a malformed
                     response, not as judgement: the store is the keeper's only
                     durable memory and [rewrite_facts_atomically] renames over
                     the sole copy, so the rows are unrecoverable. A truncated
                     response that loses its [groups] array while retaining
                     [drop_indices] produces exactly this shape. Only total live
                     erasure is refused — a large deletion over a mostly
                     redundant store remains legitimate when at least one live
                     fact survives, so no ratio or numeric floor is imposed. *)
                  if live_survivors = []
                  then Plan_rejected_total_deletion { before }
                  else if dry_run
                  then Consolidated { before; after }
                  else
                    rewrite_if_snapshot_current
                      ?clock
                      ~fresh_now
                      ~keeper_id
                      ~facts
                      ~plan_facts:live
                      ~survivors
                      ~before
                      ~after
                      ())
              | Ok _ -> invalid_structured_response Consolidation.Non_object_json)
          )
;;
