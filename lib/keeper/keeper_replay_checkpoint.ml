(** Canonical replay checkpoint projection and response-capture policy. *)

type replay_suffix_prune_reason =
  | Canonical_success_replay

let replay_suffix_prune_reason_to_string = function
  | Canonical_success_replay -> "canonical_success_replay"
;;

let replay_response_text_for_capture ~suppress_visible_response ~response_text =
  if suppress_visible_response || String.trim response_text = ""
  then None
  else Some response_text
;;

let replay_response_text_for_persistence ~suppress_visible_response ~response_text =
  replay_response_text_for_capture ~suppress_visible_response ~response_text
;;

type wire_capture_response_suppression_reason =
  | Control_checkpoint

let wire_capture_response_suppression_reasons ~control_checkpoint =
  if control_checkpoint then [ Control_checkpoint ] else []
;;

let wire_capture_response_suppression_reason_label = function
  | Control_checkpoint -> "control_checkpoint"
;;

let emit_wire_capture_response_suppressed_metric ~keeper_name reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string WireCaptureResponseSuppressed)
    ~labels:
      [ ("keeper", keeper_name)
      ; ("reason", wire_capture_response_suppression_reason_label reason)
      ]
    ()
;;

let emit_wire_capture_response_suppressed_metrics ~keeper_name reasons =
  List.iter
    (emit_wire_capture_response_suppressed_metric ~keeper_name)
    reasons
;;

let is_trailing_blank_assistant (message : Agent_sdk.Types.message) =
  match message.role, message.content with
  | Agent_sdk.Types.Assistant, [] -> true
  | Agent_sdk.Types.Assistant, blocks ->
    List.for_all
      (function
        | Agent_sdk.Types.Text text -> String.trim text = ""
        | _ -> false)
      blocks
  | _, _ -> false
;;

let drop_trailing_blank_assistants messages =
  let rec drop dropped = function
    | message :: rest when is_trailing_blank_assistant message -> drop true rest
    | reversed -> List.rev reversed, dropped
  in
  drop false (List.rev messages)
;;

let canonical_success_replay_checkpoint
      ~(history_messages : Agent_sdk.Types.message list)
      ~(session_id : string)
      ~(response_text : string)
      (checkpoint : Agent_sdk.Checkpoint.t)
  =
  match
    Keeper_replay_prefix.split
      ~prefix:history_messages
      checkpoint.Agent_sdk.Checkpoint.messages
  with
  | Ok current_suffix ->
       (* A blank visible response is not authority to erase typed replay. The
          suffix may contain an actual user input, ToolUse/ToolResult pair,
          thinking, or media whose effect has already happened. Remove only an
          inert trailing Assistant shell; the typed skipped-wake rule above owns
          the autonomous marker independently. *)
       let current_suffix, blank_assistant_dropped =
         if String.trim response_text = ""
         then drop_trailing_blank_assistants current_suffix
         else current_suffix, false
       in
       let replay_suffix_pruned =
         if blank_assistant_dropped
         then Some Canonical_success_replay
         else None
       in
       let checkpoint =
         if String.trim response_text = ""
         then
           { checkpoint with
             Agent_sdk.Checkpoint.session_id
           ; messages = history_messages @ current_suffix
           ; working_context = None
           }
         else
           (* [split] already proved that [checkpoint.messages] is exactly the
              validated history prefix followed by [current_suffix]. Keep that
              immutable list when no replay edit is required: rebuilding the
              prefix here hid that the pipeline checkpoint had already been
              durably persisted. *)
           let base_messages = checkpoint.messages in
           let messages =
             if
               List.exists
                 (fun (msg : Agent_sdk.Types.message) ->
                    msg.role = Agent_sdk.Types.Assistant)
                 current_suffix
             then base_messages
             else
               base_messages
               @
               [ Agent_sdk.Types.make_message
                   ~role:Agent_sdk.Types.Assistant
                   [ Agent_sdk.Types.Text response_text ]
               ]
           in
           Keeper_context_core.patch_checkpoint_last_assistant
             { checkpoint with Agent_sdk.Checkpoint.messages }
             ~session_id
             ~response_text
       in
       Ok (checkpoint, replay_suffix_pruned)
  | Error _ ->
    Error
      "refusing to save checkpoint: canonical replay persistence requires \
       checkpoint messages to match pre-turn history prefix"
;;

let observation_replay_checkpoint
      ~(history_messages : Agent_sdk.Types.message list)
      ~(session_id : string)
      (checkpoint : Agent_sdk.Checkpoint.t)
  =
  match
    Keeper_replay_prefix.split
      ~prefix:history_messages
      checkpoint.Agent_sdk.Checkpoint.messages
  with
  | Ok _ ->
    Ok
      ( { checkpoint with
          Agent_sdk.Checkpoint.session_id
        }
      , None )
  | Error _ ->
    Error
      "refusing to save execution-observation checkpoint: messages do not match pre-turn history prefix"
;;

let checkpoint_for_replay_persistence
      ~(history_messages : Agent_sdk.Types.message list)
      ~(session_id : string)
      ~(response_text : string)
      ?(stop_reason = Runtime_agent.Completed)
      (checkpoint : Agent_sdk.Checkpoint.t)
  =
  match stop_reason with
  | Runtime_agent.InputRequired _ ->
    (* The elicitation request can follow a current-turn tool result. Blank
       response canonicalization and completion-contract pruning must not
       remove that suffix; prefix validation still fails closed. *)
    (match
       Keeper_replay_prefix.split
         ~prefix:history_messages
         checkpoint.Agent_sdk.Checkpoint.messages
     with
     | Ok (_ :: _) ->
       Ok
         ( { checkpoint with
             Agent_sdk.Checkpoint.session_id
           }
         , None )
     | Ok [] ->
       Error
         "refusing to save input-required checkpoint without a current-turn \
          replay suffix"
     | Error _ ->
       Error
         "refusing to save input-required checkpoint: messages do not match \
          pre-turn history prefix")
  | Runtime_agent.Yielded_to_chat_waiting _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Awaiting_external_effect _
  | Runtime_agent.Yielded_after_repeated_tool_call _ ->
    (* A control-boundary checkpoint retains the current-turn tool result so
       resumption cannot repeat an already committed effect. *)
    observation_replay_checkpoint ~history_messages ~session_id checkpoint
  | Runtime_agent.Completed ->
    canonical_success_replay_checkpoint
      ~history_messages
      ~session_id
      ~response_text
      checkpoint
;;

(* OAS constructs the mutation-boundary checkpoint and then installs the same
   immutable message values on the agent state. The list spines are rebuilt, so
   list physical equality is too strict; comparing each message record by
   identity proves the state boundary without hashing or scanning large text and
   tool-result bodies. *)
let rec messages_share_values_by_identity left right =
  match left, right with
  | [], [] -> true
  | left_message :: left_rest, right_message :: right_rest
    when left_message == right_message ->
    messages_share_values_by_identity left_rest right_rest
  | _ -> false
;;

let select_finalization_checkpoint
    ~(last_persisted_checkpoint : Agent_sdk.Checkpoint.t option)
    (result_checkpoint : Agent_sdk.Checkpoint.t) =
  match last_persisted_checkpoint with
  | Some persisted
    when Int.equal persisted.turn_count result_checkpoint.turn_count
         && messages_share_values_by_identity
              persisted.messages
              result_checkpoint.messages ->
    persisted, true
  | Some _ | None -> result_checkpoint, false
;;

let finalization_checkpoint_already_persisted
    ~source_already_persisted
    ~(source : Agent_sdk.Checkpoint.t)
    ~(patched : Agent_sdk.Checkpoint.t)
    ~replay_suffix_pruned =
  source_already_persisted
  && Option.is_none replay_suffix_pruned
  && String.equal source.session_id patched.session_id
  && source.messages == patched.messages
  && source.working_context == patched.working_context
;;
