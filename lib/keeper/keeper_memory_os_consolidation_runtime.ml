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
type complete_fn = Keeper_memory_llm_summary.complete_fn

let default_complete ~sw ~net ?clock ~config ~messages () =
  Llm_provider.Complete.complete ~sw ~net ?clock ~config ~messages ()
;;

let user_message text : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.User
  ; content = [ Agent_sdk.Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let with_timeout ?clock ~timeout_sec f =
  match clock with
  | None -> Some (f ())
  | Some clock ->
    (try Some (Eio.Time.with_timeout_exn clock timeout_sec f) with
     | Eio.Time.Timeout -> None)
;;

let response_text (response : Agent_sdk.Types.api_response) : string option =
  let text =
    response.content
    |> List.filter_map (function
      | Agent_sdk.Types.Text s -> Some s
      | _ -> None)
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
    |> String.concat "\n"
    |> String.trim
  in
  if String.equal text "" then None else Some text
;;

(* Below this many facts there is nothing to consolidate; skip the LLM call. *)
let min_facts_to_consolidate = 4

(* The plan can list many groups over a large store, so allow more than the
   512-token summary budget. *)
let consolidation_max_tokens = 2048

type outcome =
  | Skipped_too_few of int
  | Transport_failed of string
  | Unparseable of string
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
  { provider_cfg with
    Llm_provider.Provider_config.max_tokens
  ; temperature = Some 0.0
  ; tool_choice = None
  ; disable_parallel_tool_use = true
  }
  |> Keeper_memory_os_structured_schema.apply_to_provider_config
       Keeper_memory_os_structured_schema.consolidation_plan_output_schema
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

(* Read [keeper_id]'s facts, ask the model for a consolidation plan, apply it, and
   (unless [dry_run]) rewrite the store atomically. Returns what happened without
   raising for the expected failure modes (too few facts, transport error,
   unparseable plan) so a caller fiber stays alive. *)
let consolidate_keeper
      ?(complete = default_complete)
      ?clock
      ?(timeout_sec = Env_config_governance.Inference.timeout_seconds)
      ?(dry_run = false)
      ~sw
      ~net
      ~provider_cfg
      ~now
      ~keeper_id
      ()
  =
  match Io.read_facts_all_strict ~keeper_id with
  | Error msg -> Unparseable ("consolidation fact store read failed: " ^ msg)
  | Ok facts ->
    let before = List.length facts in
    if before < min_facts_to_consolidate
    then Skipped_too_few before
    else
      match messages_for_consolidation facts with
      | Error msg -> Unparseable msg
      | Ok messages ->
        let config = provider_for_consolidation provider_cfg in
        (match
           with_timeout ?clock ~timeout_sec (fun () ->
             complete ~sw ~net ?clock ~config ~messages ())
         with
         | None -> Transport_failed "consolidation provider timed out"
         | Some (Error _) -> Transport_failed "consolidation provider transport error"
         | Some (Ok response) ->
           (match response_text response with
            | None -> Unparseable "consolidation provider returned empty response"
            | Some raw ->
              (match Consolidation.plan_of_string raw with
               | None -> Unparseable "consolidation provider returned invalid plan JSON"
               | Some plan ->
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
                     ())))
;;
