type replay_journal =
  | Replay_journal_recorded
  | Replay_journal_already_recorded
  | Replay_grant_not_consumed

type repair_stage =
  | Resolution_lookup
  | Request_decode
  | Evidence_storage
  | Evidence_retrieval
  | Replay_journal
  | Stale_grant_retirement
  | Invalid_resolution_state

type outcome =
  | Not_applicable
  | Applied of
      { operation : string
      ; output_ref : Tool_output.artifact_ref
      ; journal : replay_journal
      }
  | Applied_with_warning of
      { operation : string
      ; detail_ref : Tool_output.artifact_ref
      ; journal : replay_journal
      }
  | Failed of
      { operation : string
      ; detail_ref : Tool_output.artifact_ref
      ; journal : replay_journal
      }
  | Indeterminate of
      { operation : string
      ; detail_ref : Tool_output.artifact_ref
      ; journal : replay_journal
      }
  | Repair_required of
      { operation : string
      ; stage : repair_stage
      ; detail : string
      }

let repair_stage_to_string = function
  | Resolution_lookup -> "resolution_lookup"
  | Request_decode -> "request_decode"
  | Evidence_storage -> "evidence_storage"
  | Evidence_retrieval -> "evidence_retrieval"
  | Replay_journal -> "replay_journal"
  | Stale_grant_retirement -> "stale_grant_retirement"
  | Invalid_resolution_state -> "invalid_resolution_state"
;;

let replay_journal_to_string = function
  | Replay_journal_recorded -> "recorded"
  | Replay_journal_already_recorded -> "already_recorded"
  | Replay_grant_not_consumed -> "grant_not_consumed"
;;

let payload_fingerprint payload =
  Digestif.SHA256.(digest_string payload |> to_hex)
;;

let persist_replay_artifact ~base_path payload =
  try
    let store = Tool_blob_store.create ~base_path in
    Ok
      (Tool_blob_store.put_durable
         store
         ~bytes:payload
         ~mime:"text/plain")
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let detail = Printexc.to_string exn in
    Log.Keeper.error
      "Gate replay result artifact persistence failed bytes=%d sha256=%s error_sha256=%s"
      (String.length payload)
      (payload_fingerprint payload)
      (payload_fingerprint detail);
    Error detail
;;

let replay_evidence_persister_override
  : ( base_path:string
      -> string
      -> (Tool_output.artifact_ref, string) result )
      option
      Atomic.t
  =
  Atomic.make None
;;

let persist_replay_evidence ~base_path payload =
  match Atomic.get replay_evidence_persister_override with
  | None -> persist_replay_artifact ~base_path payload
  | Some persist -> persist ~base_path payload
;;

(* Every model-facing Gate replay/resolution instruction lives in a managed
   template under the keeper.gate_replay prefix; the execution path only picks
   the key and supplies the data. A template that does not render is logged
   and falls back to the bare data, never to prose written here. Defined
   ahead of [retrieve_replay_artifact]: the artifact-integrity arms below
   render through the same contract. *)
let render_gate_replay_prompt key vars ~fallback =
  match Prompt_registry.render_prompt_template key vars with
  | Ok text -> String.trim text
  | Error detail ->
    Log.Keeper.error
      "gate replay prompt %s did not render, falling back to the bare data: %s"
      key
      detail;
    fallback
;;

let retrieve_replay_artifact ~base_path artifact_ref =
  let store = Tool_blob_store.create ~base_path in
  match Tool_blob_store.fetch store ~sha256:artifact_ref.Tool_output.sha256 with
  | Error error ->
    Error (Tool_blob_store.fetch_error_to_string error)
  | Ok None ->
    Error
      (render_gate_replay_prompt
         Prompt_names.keeper_gate_replay_artifact_missing
         [ "sha256", artifact_ref.Tool_output.sha256 ]
         ~fallback:artifact_ref.Tool_output.sha256)
  | Ok (Some payload) ->
    let actual_bytes = String.length payload in
    if actual_bytes = artifact_ref.Tool_output.bytes
    then Ok payload
    else
      Error
        (render_gate_replay_prompt
           Prompt_names.keeper_gate_replay_artifact_length_mismatch
           [ "sha256", artifact_ref.Tool_output.sha256
           ; "expected", string_of_int artifact_ref.Tool_output.bytes
           ; "actual", string_of_int actual_bytes
           ]
           ~fallback:
             (Printf.sprintf
                "replay artifact %s expected=%d actual=%d"
                artifact_ref.Tool_output.sha256
                artifact_ref.Tool_output.bytes
                actual_bytes))
;;

let outcome_to_string = function
  | Not_applicable -> "not_applicable"
  | Applied { operation; output_ref; journal } ->
    Printf.sprintf
      "applied operation=%s journal=%s output_bytes=%d output_sha256=%s"
      operation
      (replay_journal_to_string journal)
      output_ref.Tool_output.bytes
      output_ref.Tool_output.sha256
  | Applied_with_warning { operation; detail_ref; journal } ->
    Printf.sprintf
      "applied_with_warning operation=%s journal=%s detail_bytes=%d detail_sha256=%s"
      operation
      (replay_journal_to_string journal)
      detail_ref.Tool_output.bytes
      detail_ref.Tool_output.sha256
  | Failed { operation; detail_ref; journal } ->
    Printf.sprintf
      "failed operation=%s journal=%s detail_bytes=%d detail_sha256=%s"
      operation
      (replay_journal_to_string journal)
      detail_ref.Tool_output.bytes
      detail_ref.Tool_output.sha256
  | Indeterminate { operation; detail_ref; journal } ->
    Printf.sprintf
      "indeterminate operation=%s journal=%s detail_bytes=%d detail_sha256=%s"
      operation
      (replay_journal_to_string journal)
      detail_ref.Tool_output.bytes
      detail_ref.Tool_output.sha256
  | Repair_required { operation; stage; detail } ->
    Printf.sprintf
      "repair_required operation=%s stage=%s detail_sha256=%s"
      operation
      (repair_stage_to_string stage)
      (payload_fingerprint detail)
;;

(* Replay recognizes exactly the identity its producer submits; every other
   approved operation stays with its own producer. The vocabulary and the
   replayable set live in the Gate itself ({!Keeper_gate}), so the deferred
   payload's on_approve promise cannot drift from what this engine spends. *)
let write_operation = Keeper_gate.filesystem_write_gate_operation
let execute_operation = Keeper_gate.tool_execute_gate_operation
let network_read_operation = Keeper_gate.network_read_gate_operation
let connector_post_operation = Keeper_gate.connector_post_gate_operation
let identity_operation = Keeper_gate.identity_call_gate_operation

(* Speak is the one voice leaf the Gate authorizes: the spoken text leaves
   for a TTS endpoint, so its content stays judge-reviewed, and playback is
   not wall-clock bound — a post-approval replay still lands. Listen is the
   opposite: its microphone window expires while the judge runs, so it never
   enters the Gate (see keeper_tool_voice_runtime.ml). *)
let voice_speak_operation = Keeper_gate.voice_speak_gate_operation
;;

(* The producer owns both the argument schema and the effect encoding, so it
   owns the inversion; replay only decides whether to spend the grant. *)
let write_args_of_gate_input =
  Keeper_tool_filesystem_runtime.replay_args_of_gate_input
;;

let execute_args_of_gate_input =
  Keeper_tool_execute_runtime.replay_args_of_gate_input
;;

let network_read_of_gate_input =
  Keeper_tool_in_process_runtime.network_read_replay_of_gate_input
;;

let connector_post_of_gate_input =
  Keeper_tool_in_process_runtime.connector_post_replay_of_gate_input
;;

let identity_of_gate_input = Keeper_identity_gate.replay_of_gate_input

(* Which approved operations this module can spend without the Keeper
   re-emitting the call. The set and its operation vocabulary live in the
   Gate ({!Keeper_gate.replayable_operation}) so the deferred payload's
   promise and this engine's dispatch answer to one definition; separated
   from the replay body so the set stays assertable: a decode function that
   exists but is never dispatched to looks exactly like a working replay
   from the outside. *)
type replayable = Keeper_gate.replayable

let replayable_of_operation = Keeper_gate.replayable_operation
;;

type effect_outcome =
  | Effect_applied of string
  | Effect_applied_with_warning of string
  | Effect_failed of string
  | Effect_indeterminate of string

type replay_execution =
  { outcome : outcome
  ; terminal_effect_receipt :
      Keeper_tool_execution.terminal_effect_receipt option
  }

let replay_execution ?terminal_effect_receipt outcome =
  { outcome; terminal_effect_receipt }
;;

let applied_terminal_effect_receipt replay_effect receipt =
  match replay_effect with
  | Effect_applied _ | Effect_applied_with_warning _ -> receipt
  | Effect_failed _ | Effect_indeterminate _ -> None
;;

let replay_artifact_identity artifact_ref =
  Tool_output.with_preview artifact_ref ""
;;

let persist_replay_effect ~base_path = function
  | Effect_applied output ->
    Result.map
      (fun output_ref ->
         Keeper_approval_queue.Replay_applied
           (replay_artifact_identity output_ref))
      (persist_replay_evidence ~base_path output)
  | Effect_applied_with_warning detail ->
    Result.map
      (fun detail_ref ->
         Keeper_approval_queue.Replay_applied_with_warning
           (replay_artifact_identity detail_ref))
      (persist_replay_evidence ~base_path detail)
  | Effect_failed detail ->
    Result.map
      (fun detail_ref ->
         Keeper_approval_queue.Replay_failed
           (replay_artifact_identity detail_ref))
      (persist_replay_evidence ~base_path detail)
  | Effect_indeterminate detail ->
    Result.map
      (fun detail_ref ->
         Keeper_approval_queue.Replay_indeterminate
           (replay_artifact_identity detail_ref))
      (persist_replay_evidence ~base_path detail)
;;

module Repair_map = Map.Make (String)

type pending_repair =
  { operation : string
  ; replay_effect : effect_outcome
  ; terminal_effect_receipt :
      Keeper_tool_execution.terminal_effect_receipt option
  }

(* A Keeper turn already owns the per-Keeper admission mutex before replay
   setup. This map is not another execution owner: it retains a completed
   effect's exact result only while its durable evidence/journal is repaired. *)
let pending_repairs = Atomic.make Repair_map.empty

let repair_key ~base_path ~approval_id =
  base_path ^ "\000" ^ approval_id
;;

let rec update_pending_repairs update =
  let current = Atomic.get pending_repairs in
  let next = update current in
  if not (Atomic.compare_and_set pending_repairs current next)
  then update_pending_repairs update
;;

let remember_pending_repair ~base_path ~approval_id repair =
  let key = repair_key ~base_path ~approval_id in
  update_pending_repairs (Repair_map.add key repair)
;;

let forget_pending_repair ~base_path ~approval_id =
  let key = repair_key ~base_path ~approval_id in
  update_pending_repairs (Repair_map.remove key)
;;

let find_pending_repair ~base_path ~approval_id =
  Repair_map.find_opt
    (repair_key ~base_path ~approval_id)
    (Atomic.get pending_repairs)
;;

let summarize_execution ~operation (execution : Keeper_tool_execution.t) =
  match execution.disposition with
  | Tool_result.Completed _ -> Effect_applied execution.raw_output
  | Tool_result.Deferred _ ->
    (* The re-derived canonical input no longer matches the approval — what
       the approval pinned is not what replay would act on now. The effect
       stays unapplied and its new request follows the ordinary Gate. *)
    Effect_failed
      (render_gate_replay_prompt
         Prompt_names.keeper_gate_replay_approval_input_drifted
         [ "operation", operation ]
         ~fallback:("approval_input_drifted operation=" ^ operation))
  | Tool_result.Failed _ ->
    (match execution.failure_effect_disposition with
     | Tool_result.Proven_pre_effect -> Effect_failed execution.raw_output
     | Tool_result.Proven_post_effect ->
       Effect_applied_with_warning execution.raw_output
     | Tool_result.Effect_outcome_unknown ->
       Effect_indeterminate execution.raw_output)
;;

let retire_stale_grant
      ~base_path
      ~approval_id
      (request : Keeper_approval_queue.approved_resolution_request)
  =
  match
    Keeper_approval_queue.consume_approved_resolution
      ~base_path
      ~id:approval_id
      ~keeper_name:request.keeper_name
      ~tool_name:request.tool_name
      ~input:request.input
  with
  | Ok (Keeper_approval_queue.Consumption_committed _)
  | Ok Keeper_approval_queue.Consumption_already_committed ->
    Ok ()
  | Ok Keeper_approval_queue.Consumption_not_matching ->
    Error
      (render_gate_replay_prompt
         Prompt_names.keeper_gate_replay_approval_consumption_mismatch
         []
         ~fallback:"approval_consumption_mismatch")
  | Error error ->
    Error (Keeper_approval_queue.grant_error_to_string error)
;;

let replay_journal ~base_path ~approval_id outcome =
  Keeper_approval_queue.record_consumed_resolution_replay
    ~base_path
    ~id:approval_id
    ~outcome
;;

let replay_journal_status ~base_path ~approval_id replay_outcome =
  match replay_journal ~base_path ~approval_id replay_outcome with
  | Ok Keeper_approval_queue.Replay_recorded -> Ok Replay_journal_recorded
  | Ok Keeper_approval_queue.Replay_already_recorded ->
    Ok Replay_journal_already_recorded
  | Error (Keeper_approval_queue.Grant_replay_not_consumed _) ->
    Ok Replay_grant_not_consumed
  | Error error ->
    Error (Keeper_approval_queue.grant_error_to_string error)
;;

let project_replay_outcome_to_chat ~base_path ~approval_id replay_outcome =
  match
    Keeper_approval_queue.approved_resolution_delivery
      ~base_path
      ~id:approval_id
  with
  | Error error ->
    Log.Keeper.warn
      "approved Gate replay chat projection lookup failed approval=%s: %s"
      approval_id
      (Keeper_approval_queue.grant_error_to_string error)
  | Ok { request; _ } ->
    (match
       Keeper_approval_queue.ensure_replay_chat_projection
         ~base_path
         ~keeper_name:request.keeper_name
         ~approval_id
         ~tool_name:(Some request.tool_name)
         ~call_summary:(Keeper_approval_queue.call_summary_of_input request.input)
         ~outcome:replay_outcome
     with
     | Ok () -> ()
     | Error detail ->
       Log.Keeper.warn
         ~keeper_name:request.keeper_name
         "approved Gate replay chat projection deferred approval=%s: %s"
         approval_id
         detail)
;;

let replayed_outcome
      ~base_path
      ~approval_id
      ~operation
      ?terminal_effect_receipt
      replay_effect
  =
  let terminal_effect_receipt =
    applied_terminal_effect_receipt replay_effect terminal_effect_receipt
  in
  remember_pending_repair
    ~base_path
    ~approval_id
    { operation; replay_effect; terminal_effect_receipt };
  match persist_replay_effect ~base_path replay_effect with
  | Error detail ->
    replay_execution
      ?terminal_effect_receipt
      (Repair_required { operation; stage = Evidence_storage; detail })
  | Ok replay_outcome ->
    (match replay_journal_status ~base_path ~approval_id replay_outcome with
     | Error detail ->
       replay_execution
         ?terminal_effect_receipt
         (Repair_required { operation; stage = Replay_journal; detail })
     | Ok Replay_grant_not_consumed ->
       replay_execution
         ?terminal_effect_receipt
         (Repair_required
            { operation
            ; stage = Stale_grant_retirement
            ; detail = replay_journal_to_string Replay_grant_not_consumed
            })
     | Ok (Replay_journal_recorded | Replay_journal_already_recorded as journal) ->
       forget_pending_repair ~base_path ~approval_id;
       project_replay_outcome_to_chat ~base_path ~approval_id replay_outcome;
       let outcome =
         match replay_outcome with
         | Keeper_approval_queue.Replay_applied output_ref ->
           Applied { operation; output_ref; journal }
         | Keeper_approval_queue.Replay_applied_with_warning detail_ref ->
           Applied_with_warning { operation; detail_ref; journal }
         | Keeper_approval_queue.Replay_failed detail_ref ->
           Failed { operation; detail_ref; journal }
         | Keeper_approval_queue.Replay_indeterminate detail_ref ->
           Indeterminate { operation; detail_ref; journal }
       in
       replay_execution ?terminal_effect_receipt outcome)
;;

let settle_replay_effect
      ~base_path
      ~approval_id
      ~(request : Keeper_approval_queue.approved_resolution_request)
      ?terminal_effect_receipt
      ~operation
      replay_effect
  =
  (* A producer normally consumes the one-shot grant immediately before its
     exact effect. A proven pre-effect failure can return before that boundary
     (for example, while creating its sandbox). Retire any such still-
     unconsumed grant before publishing a terminal replay result so the same
     failed operation is not attempted on every queued wake. *)
  remember_pending_repair
    ~base_path
    ~approval_id
    { operation; replay_effect; terminal_effect_receipt };
  match retire_stale_grant ~base_path ~approval_id request with
  | Error detail ->
    replay_execution
      ?terminal_effect_receipt
      (Repair_required
         { operation
         ; stage = Stale_grant_retirement
         ; detail
         })
  | Ok () ->
    replayed_outcome
      ~base_path
      ~approval_id
      ~operation
      ?terminal_effect_receipt
      replay_effect
;;

let durable_replay_execution
      ~base_path
      ~operation
      ~journal
      ?terminal_effect_receipt
      replay_outcome
  =
  let verified =
    match replay_outcome with
    | Keeper_approval_queue.Replay_applied output_ref ->
      Result.map
        (fun _ -> `Applied output_ref)
        (retrieve_replay_artifact ~base_path output_ref)
    | Keeper_approval_queue.Replay_applied_with_warning detail_ref ->
      Result.map
        (fun _ -> `Applied_with_warning detail_ref)
        (retrieve_replay_artifact ~base_path detail_ref)
    | Keeper_approval_queue.Replay_failed detail_ref ->
      Result.map
        (fun _ -> `Failed detail_ref)
        (retrieve_replay_artifact ~base_path detail_ref)
    | Keeper_approval_queue.Replay_indeterminate detail_ref ->
      Result.map
        (fun _ -> `Indeterminate detail_ref)
        (retrieve_replay_artifact ~base_path detail_ref)
  in
  let outcome =
    match verified with
    | Ok (`Applied output_ref) -> Applied { operation; output_ref; journal }
    | Ok (`Applied_with_warning detail_ref) ->
      Applied_with_warning { operation; detail_ref; journal }
    | Ok (`Failed detail_ref) -> Failed { operation; detail_ref; journal }
    | Ok (`Indeterminate detail_ref) ->
      Indeterminate { operation; detail_ref; journal }
    | Error detail ->
      Repair_required { operation; stage = Evidence_retrieval; detail }
  in
  replay_execution ?terminal_effect_receipt outcome
;;

let durable_replay_outcome ~base_path ~operation ~journal replay_outcome =
  (durable_replay_execution
     ~base_path
     ~operation
     ~journal
     replay_outcome)
    .outcome
;;

type replay_evidence_effect =
  | Evidence_applied
  | Evidence_applied_with_warning
  | Evidence_failed
  | Evidence_indeterminate

type model_evidence =
  { approval_id : string
  ; operation : string
  ; effect_kind : replay_evidence_effect
  ; journal : replay_journal
  ; artifact_ref : Tool_output.artifact_ref
  }

type model_message =
  { text : string
  ; replay_evidence : model_evidence option
  }

let plain_model_message text = { text; replay_evidence = None }

let replay_evidence_effect_to_string = function
  | Evidence_applied -> "applied"
  | Evidence_applied_with_warning -> "applied_with_warning"
  | Evidence_failed -> "failed"
  | Evidence_indeterminate -> "indeterminate"
;;

let replay_evidence_json evidence =
  let payload_field =
    match evidence.effect_kind with
    | Evidence_applied -> "untrusted_tool_output_ref"
    | Evidence_applied_with_warning | Evidence_failed | Evidence_indeterminate ->
      "detail_ref"
  in
  `Assoc
    [ "approval_id", `String evidence.approval_id
    ; "operation", `String evidence.operation
    ; "effect", `String (replay_evidence_effect_to_string evidence.effect_kind)
    ; "replay_journal", `String (replay_journal_to_string evidence.journal)
    ; ( payload_field
      , Tool_output.normalized_artifact_ref_to_json evidence.artifact_ref )
    ]
  |> Yojson.Safe.to_string
;;

let replay_evidence_fragment evidence =
  let key =
    match evidence.effect_kind with
    | Evidence_applied -> Prompt_names.keeper_gate_replay_evidence_applied
    | Evidence_applied_with_warning ->
      Prompt_names.keeper_gate_replay_evidence_applied_with_warning
    | Evidence_failed -> Prompt_names.keeper_gate_replay_evidence_failed
    | Evidence_indeterminate -> Prompt_names.keeper_gate_replay_evidence_indeterminate
  in
  let evidence_json = replay_evidence_json evidence in
  render_gate_replay_prompt key [ "evidence_json", evidence_json ] ~fallback:evidence_json
  |> Inference_utils.sanitize_text_utf8
;;

let canonical_replay_evidence_fragment evidence =
  replay_evidence_fragment evidence
;;

let replay_model_message
      ~approval_id
      ~user_message
      ~operation
      ~effect_kind
      ~journal
      artifact_ref
  =
  let artifact_ref = replay_artifact_identity artifact_ref in
  let replay_evidence =
    { approval_id; operation; effect_kind; journal; artifact_ref }
  in
  { text =
      String.concat
        "\n"
        [ user_message; ""; canonical_replay_evidence_fragment replay_evidence ]
  ; replay_evidence = Some replay_evidence
  }
;;

let append_model_evidence ~approval_id ~user_message = function
  | Not_applicable -> plain_model_message user_message
  | Applied { operation; output_ref; journal } ->
    replay_model_message
      ~approval_id
      ~user_message
      ~operation
      ~effect_kind:Evidence_applied
      ~journal
      output_ref
  | Applied_with_warning { operation; detail_ref; journal } ->
    replay_model_message
      ~approval_id
      ~user_message
      ~operation
      ~effect_kind:Evidence_applied_with_warning
      ~journal
      detail_ref
  | Failed { operation; detail_ref; journal } ->
    replay_model_message
      ~approval_id
      ~user_message
      ~operation
      ~effect_kind:Evidence_failed
      ~journal
      detail_ref
  | Indeterminate { operation; detail_ref; journal } ->
    replay_model_message
      ~approval_id
      ~user_message
      ~operation
      ~effect_kind:Evidence_indeterminate
      ~journal
      detail_ref
  | Repair_required { operation; stage; detail } ->
    let repair_fragment =
      render_gate_replay_prompt
        Prompt_names.keeper_gate_replay_repair_required
        [ "approval_id", approval_id
        ; "operation", operation
        ; "stage", repair_stage_to_string stage
        ; "detail_sha256", payload_fingerprint detail
        ]
        ~fallback:
          (String.concat
             "\n"
             [ Printf.sprintf "- approval_id: %s" approval_id
             ; Printf.sprintf "- operation: %s" operation
             ; Printf.sprintf "- stage: %s" (repair_stage_to_string stage)
             ; Printf.sprintf "- detail_sha256: %s" (payload_fingerprint detail)
             ])
    in
    plain_model_message (String.concat "\n" [ user_message; ""; repair_fragment ])
;;

let append_model_evidence_block evidence blocks =
  blocks
  @ [ Agent_core.Types.Text (canonical_replay_evidence_fragment evidence) ]
;;

let project_model_input ~base_path:_ evidence messages =
  let referenced = replay_evidence_fragment evidence in
  Ok (messages @ [ Agent_core.Types.user_msg referenced ])
;;

let approved_resolution_message ~approval_id ~tool_name ~input ~user_message =
  let resolution_fragment =
    match replayable_of_operation tool_name with
    | Some _ ->
      render_gate_replay_prompt
        Prompt_names.keeper_gate_replay_resolution_without_replay_outcome
        [ "approval_id", approval_id; "operation", tool_name ]
        ~fallback:
          (String.concat
             "\n"
             [ Printf.sprintf "- approval_id: %s" approval_id
             ; Printf.sprintf "- operation: %s" tool_name
             ])
    | None ->
      let exact_input = Yojson.Safe.pretty_to_string input in
      render_gate_replay_prompt
        Prompt_names.keeper_gate_replay_resolution_exact_input
        [ "approval_id", approval_id
        ; "operation", tool_name
        ; "exact_input", exact_input
        ]
        ~fallback:
          (String.concat
             "\n"
             [ Printf.sprintf "- approval_id: %s" approval_id
             ; Printf.sprintf "- operation: %s" tool_name
             ; exact_input
             ])
  in
  String.concat "\n" [ user_message; ""; resolution_fragment ]
;;

let user_message_with_hitl_resolution ~base_path ~user_message = function
  | Some
      { Keeper_event_queue.approval_id
      ; decision = Keeper_event_queue.Hitl_approved
      ; _
      } ->
    (match
       Keeper_approval_queue.approved_resolution_delivery
         ~base_path
         ~id:approval_id
     with
     | Ok
         { request
         ; state = Keeper_approval_queue.Resolution_unconsumed
         ; replay_outcome = None
         } ->
       plain_model_message
         (approved_resolution_message
            ~approval_id
            ~tool_name:request.tool_name
            ~input:request.input
            ~user_message)
     | Ok
         { request
         ; state = Keeper_approval_queue.Resolution_consumed
         ; replay_outcome = Some replay_outcome
         } ->
       Log.Keeper.info
         "approved Gate replay result already durable approval=%s"
         approval_id;
       durable_replay_outcome
         ~base_path
         ~operation:request.tool_name
         ~journal:Replay_journal_already_recorded
         replay_outcome
       |> append_model_evidence ~approval_id ~user_message
     | Ok
         { request
         ; state = Keeper_approval_queue.Resolution_consumed
         ; replay_outcome = None
         } ->
       Log.Keeper.error
         "approved Gate grant consumed without replay result approval=%s operation=%s"
         approval_id
         request.tool_name;
       plain_model_message
         (String.concat
            "\n"
            [ user_message
            ; ""
            ; render_gate_replay_prompt
                Prompt_names.keeper_gate_replay_resolution_consumed_without_outcome
                [ "approval_id", approval_id; "operation", request.tool_name ]
                ~fallback:
                  (String.concat
                     "\n"
                     [ Printf.sprintf "- approval_id: %s" approval_id
                     ; Printf.sprintf "- operation: %s" request.tool_name
                     ; "- state: authorization consumed, replay outcome unavailable"
                     ])
            ])
     | Ok
         { state = Keeper_approval_queue.Resolution_unconsumed
         ; replay_outcome = Some _
         ; _
         } ->
       Log.Keeper.error
         "approved Gate replay result exists before grant consumption approval=%s"
         approval_id;
       plain_model_message
         (String.concat
            "\n"
            [ user_message
            ; ""
            ; render_gate_replay_prompt
                Prompt_names.keeper_gate_replay_resolution_invalid_replay_state
                [ "approval_id", approval_id ]
                ~fallback:
                  (Printf.sprintf
                     "- approval_id: %s\n- state: invalid durable replay state"
                     approval_id)
            ])
     | Error error ->
       Log.Keeper.error
         "approved Gate request unavailable approval=%s: %s"
         approval_id
         (Keeper_approval_queue.grant_error_to_string error);
       plain_model_message
         (String.concat
            "\n"
            [ user_message
            ; ""
            ; render_gate_replay_prompt
                Prompt_names.keeper_gate_replay_resolution_journal_unreadable
                [ "approval_id", approval_id ]
                ~fallback:(Printf.sprintf "- approval_id: %s" approval_id)
            ]))
  | Some
      { Keeper_event_queue.approval_id
      ; decision = Keeper_event_queue.Hitl_rejected rationale
      ; _
      } ->
    plain_model_message
      (String.concat
         "\n"
         [ user_message
         ; ""
         ; render_gate_replay_prompt
             Prompt_names.keeper_gate_replay_resolution_rejected
             [ "approval_id", approval_id; "rationale", rationale ]
             ~fallback:
               (String.concat
                  "\n"
                  [ Printf.sprintf "- approval_id: %s" approval_id
                  ; "- decision: rejected"
                  ; Printf.sprintf "- rationale: %s" rationale
                  ])
         ])
  | None -> plain_model_message user_message
;;

let compose_model_message
      ~base_path
      ~user_message
      ~hitl_resolution
      ~replay_delivery
  =
  match replay_delivery with
  | Some
      ( approval_id
      , ( ( Applied _
          | Applied_with_warning _
          | Failed _
          | Indeterminate _ )
          as outcome ) ) ->
    append_model_evidence ~approval_id ~user_message outcome
  | Some (approval_id, (Repair_required _ as outcome)) ->
    append_model_evidence ~approval_id ~user_message outcome
  | Some (_, Not_applicable) | None ->
    user_message_with_hitl_resolution
      ~base_path
      ~user_message
      hitl_resolution
;;

let connector_post_terminal_effect_receipt connector_post =
  Keeper_tool_execution.Surface_post_completed
    (Keeper_tool_in_process_runtime.connector_post_replay_target connector_post)
;;

let terminal_effect_receipt_of_durable_replay request replay_outcome =
  match
    replayable_of_operation request.Keeper_approval_queue.tool_name,
    replay_outcome
  with
  | ( Some Replay_connector_post
    , ( Keeper_approval_queue.Replay_applied _
      | Keeper_approval_queue.Replay_applied_with_warning _ ) ) ->
    Result.map
      (fun connector_post ->
         Some (connector_post_terminal_effect_receipt connector_post))
      (connector_post_of_gate_input request.input)
  | ( ( Some Replay_write
      | Some Replay_execute
      | Some Replay_network_read
      | Some Replay_identity
      | Some Replay_voice_speak
      | None )
    , _ )
  | Some Replay_connector_post,
    ( Keeper_approval_queue.Replay_failed _
    | Keeper_approval_queue.Replay_indeterminate _ ) ->
    Ok None
;;

let replay_approved_effect_with_receipt
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ?continuation_channel
      ?gate_context
      ~(grant : Keeper_gate.cycle_grant)
      ~approval_id
      ()
  =
  match
    Keeper_approval_queue.approved_resolution_delivery
      ~base_path:config.base_path
      ~id:approval_id
  with
  | Error error ->
    (match
       find_pending_repair
         ~base_path:config.base_path
         ~approval_id
     with
     | Some { operation; replay_effect; terminal_effect_receipt } ->
       replayed_outcome
         ~base_path:config.base_path
         ~approval_id
         ~operation
         ?terminal_effect_receipt
         replay_effect
     | None ->
       replay_execution
         (Repair_required
            { operation = "unknown"
            ; detail = Keeper_approval_queue.grant_error_to_string error
            ; stage = Resolution_lookup
            }))
  | Ok
      { request
      ; state = Keeper_approval_queue.Resolution_consumed
      ; replay_outcome = Some replay_outcome
      } ->
    forget_pending_repair ~base_path:config.base_path ~approval_id;
    (match terminal_effect_receipt_of_durable_replay request replay_outcome with
     | Error detail ->
       replay_execution
         (Repair_required
            { operation = request.tool_name
            ; stage = Request_decode
            ; detail
            })
     | Ok terminal_effect_receipt ->
       durable_replay_execution
         ~base_path:config.base_path
         ~operation:request.tool_name
         ~journal:Replay_journal_already_recorded
         ?terminal_effect_receipt
         replay_outcome)
  | Ok
      { request
      ; state = Keeper_approval_queue.Resolution_consumed
      ; replay_outcome = None
      } ->
    (match
       find_pending_repair
         ~base_path:config.base_path
         ~approval_id
     with
     | Some { operation; replay_effect; terminal_effect_receipt } ->
       replayed_outcome
         ~base_path:config.base_path
         ~approval_id
         ~operation
         ?terminal_effect_receipt
         replay_effect
     | None ->
       replayed_outcome
         ~base_path:config.base_path
         ~approval_id
         ~operation:request.tool_name
         (Effect_indeterminate
            (render_gate_replay_prompt
               Prompt_names.keeper_gate_replay_replay_outcome_missing_after_restart
               []
               ~fallback:"replay_outcome_missing_after_restart")))
  | Ok
      { request
      ; state = Keeper_approval_queue.Resolution_unconsumed
      ; replay_outcome = Some _
      } ->
    replay_execution
      (Repair_required
         { operation = request.tool_name
         ; stage = Invalid_resolution_state
         ; detail =
             render_gate_replay_prompt
               Prompt_names.keeper_gate_replay_replay_outcome_before_consumption
               []
               ~fallback:"replay_outcome_before_consumption"
         })
  | Ok
      { request
      ; state = Keeper_approval_queue.Resolution_unconsumed
      ; replay_outcome = None
      } ->
    let settle_effect =
      settle_replay_effect
        ~base_path:config.base_path
        ~approval_id
        ~request
    in
    let run_effect ?terminal_effect_receipt operation run =
      let execution =
        try Ok (run ()) with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Error
            (render_gate_replay_prompt
               Prompt_names.keeper_gate_replay_replay_effect_raised
               [ "detail", Printexc.to_string exn ]
               ~fallback:(Printexc.to_string exn))
      in
      match execution with
      | Error detail ->
        settle_effect
          ?terminal_effect_receipt
          ~operation
          (Effect_indeterminate detail)
      | Ok execution ->
        settle_effect
          ?terminal_effect_receipt
          ~operation
          (summarize_execution ~operation execution)
    in
    let replay ?terminal_effect_receipt_of_args operation decode run =
      match decode request.input with
      | Error detail ->
        replay_execution
          (Repair_required { operation; stage = Request_decode; detail })
      | Ok args ->
        let terminal_effect_receipt =
          Option.map
            (fun make_receipt -> make_receipt args)
            terminal_effect_receipt_of_args
        in
        run_effect ?terminal_effect_receipt operation (fun () -> run args)
    in
    (match find_pending_repair ~base_path:config.base_path ~approval_id with
     | Some { operation; replay_effect; terminal_effect_receipt } ->
       settle_effect ?terminal_effect_receipt ~operation replay_effect
     | None ->
       (match replayable_of_operation request.tool_name with
     | None -> replay_execution Not_applicable
     | Some Replay_write ->
       replay write_operation write_args_of_gate_input (fun args ->
         Keeper_tool_filesystem_runtime.handle_file_write_with_outcome
           ~turn_sandbox_factory
           ~config
           ~meta
           ~publication_recovery
           ?continuation_channel
           ?gate_context
           ~gate_grant:grant
           ~args
           ())
     | Some Replay_execute ->
       replay execute_operation execute_args_of_gate_input (fun args ->
         Keeper_tool_execute_runtime.handle_tool_execute_with_outcome
           ~turn_sandbox_factory
           ~config
           ~meta
           ?continuation_channel
           ?gate_context
           ~gate_grant:grant
           (* The host replays; there is no turn here, so no descriptor can be
              looked up and no tool dispatched. The line is refused rather
              than run as a host program of that name (#32730). *)
           ~shell_ir_rewrite:Keeper_shell_tool_command.refuse_reserved_command
           ~args
           ())
     | Some Replay_network_read ->
       (match network_read_of_gate_input request.input with
        | Error detail ->
          replay_execution
            (Repair_required
               { operation = network_read_operation
               ; stage = Request_decode
               ; detail
               })
        | Ok (Keeper_tool_in_process_runtime.Replay_web_search args) ->
          run_effect network_read_operation (fun () ->
            Keeper_tool_in_process_runtime.handle_web_search_with_outcome
              ~config
              ~meta
              ?continuation_channel
              ?gate_context
              ~gate_grant:grant
              ~args
              ())
        | Ok (Keeper_tool_in_process_runtime.Replay_web_fetch args) ->
          run_effect network_read_operation (fun () ->
            Keeper_tool_in_process_runtime.handle_web_fetch_with_outcome
              ~config
              ~meta
              ?continuation_channel
              ?gate_context
              ~gate_grant:grant
              ~args
              ()))
     | Some Replay_connector_post ->
       replay
         ~terminal_effect_receipt_of_args:connector_post_terminal_effect_receipt
         connector_post_operation
         connector_post_of_gate_input
         (fun connector_post ->
            Keeper_tool_in_process_runtime.replay_connector_post_with_outcome
              ~config
              ~meta
              ?continuation_channel
              ?gate_context
              ~gate_grant:grant
              connector_post)
     | Some Replay_identity ->
       replay identity_operation identity_of_gate_input (fun call ->
         Keeper_identity_gate.replay_call_with_outcome
           ~config
           ~meta
           ?continuation_channel
           ?gate_context
           ~gate_grant:grant
           call)
     | Some Replay_voice_speak ->
       (* The approved input is the tool call verbatim — speak takes the
          descriptor JSON itself, so replay passes it through unchanged and
          [summarize_execution] treats any Deferred it meets (input drifted
          from what was approved) as not-applied. *)
       replay voice_speak_operation (fun input -> Ok input) (fun args ->
         Keeper_tool_in_process_runtime.handle_voice_with_outcome
           ~config
           ~meta
           ?continuation_channel
           ?gate_context
           ~gate_grant:grant
           ~name:voice_speak_operation
           ~args
           ())))
;;

let replay_approved_effect
      ~config
      ~meta
      ~publication_recovery
      ~turn_sandbox_factory
      ?continuation_channel
      ?gate_context
      ~grant
      ~approval_id
      ()
  =
  (replay_approved_effect_with_receipt
     ~config
     ~meta
     ~publication_recovery
     ~turn_sandbox_factory
     ?continuation_channel
     ?gate_context
     ~grant
     ~approval_id
     ())
    .outcome
;;

module For_testing = struct
  let persist_replay_artifact = persist_replay_artifact

  let settle_pre_effect_failure ~base_path ~approval_id ~operation ~detail =
    match
      Keeper_approval_queue.approved_resolution_delivery
        ~base_path
        ~id:approval_id
    with
    | Ok
        { request
        ; state = Keeper_approval_queue.Resolution_unconsumed
        ; replay_outcome = None
        } ->
      Ok
        (settle_replay_effect
           ~base_path
           ~approval_id
           ~request
           ~operation
           (Effect_failed detail))
    | Ok _ -> Error "invalid_state"
    | Error error -> Error (Keeper_approval_queue.grant_error_to_string error)
  ;;

  let with_replay_evidence_persister persist f =
    let previous =
      Atomic.exchange replay_evidence_persister_override (Some persist)
    in
    Fun.protect
      ~finally:(fun () ->
        Atomic.set replay_evidence_persister_override previous)
      f
  ;;
end
