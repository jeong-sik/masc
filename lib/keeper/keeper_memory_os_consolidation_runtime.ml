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
   512-token summary budget. *)
let consolidation_max_tokens = 2048

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

let provider_for_consolidation (provider_cfg : Llm_provider.Provider_config.t) =
  let max_tokens =
    match provider_cfg.max_tokens with
    | Some n when n > 0 -> Some n
    | Some _ | None -> Some consolidation_max_tokens
  in
  let tuned_cfg =
    { provider_cfg with
      Llm_provider.Provider_config.max_tokens
    ; tool_choice = None
    ; disable_parallel_tool_use = true
    }
  in
  Keeper_structured_output_schema.apply_schema_or_prompt_tier
    ~log_label:"memory os consolidation output contract"
    Keeper_structured_output_schema.consolidation_plan_output_schema
    tuned_cfg
;;

module For_testing = struct
  let provider_for_consolidation = provider_for_consolidation
end

let validate_provider_for_consolidation provider_cfg =
  Llm_provider.Provider_config.validate_output_schema_request provider_cfg
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
   unparseable plan) so a caller fiber stays alive. *)
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
        let config = provider_for_consolidation provider_cfg in
        (match validate_provider_for_consolidation config with
         | Error msg -> Transport_failed ("consolidation provider config rejected: " ^ msg)
         | Ok () ->
        (match
           Keeper_provider_subcall.complete ?override:complete ~sw ~net ?clock
             ~config ~messages ()
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
                let survivors = Consolidation.apply_plan ~now ~facts plan in
                let after = List.length survivors in
                if dry_run
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
        )
;;
