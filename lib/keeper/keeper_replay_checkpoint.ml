(** Canonical replay checkpoint projection and response-capture policy. *)

type replay_suffix_prune_reason =
  | Canonical_success_replay
  | Suppressed_terminal_effect_response
  | Internal_thought_not_replayed
  | Internal_turn_not_replayed

let replay_suffix_prune_reason_to_string = function
  | Canonical_success_replay -> "canonical_success_replay"
  | Suppressed_terminal_effect_response ->
    "suppressed_terminal_effect_response"
  | Internal_thought_not_replayed -> "internal_thought_not_replayed"
  | Internal_turn_not_replayed -> "internal_turn_not_replayed"
;;

let replay_response_text_for_persistence ~suppress_visible_response ~response_text =
  if suppress_visible_response || String.trim response_text = ""
  then None
  else Some response_text
;;

let consume_replay_response
    ~suppress_visible_response
    ~response_text
    ~consume =
  replay_response_text_for_persistence
    ~suppress_visible_response
    ~response_text
  |> Option.map (fun response_text -> consume ~response_text)
;;

type wire_capture_response_suppression_reason =
  | Control_checkpoint
  (* The turn's effect already reached the reader — an approved connector post
     that a Gate replay settled before the model spoke. Anything the model then
     says is a second message about work already delivered. [Control_checkpoint]
     cannot cover this: it reads [stop_reason], and a turn that answers in plain
     text without calling a tool stops at [Completed] like any other. *)
  | Terminal_effect_settled

let wire_capture_response_suppression_reasons
      ~control_checkpoint
      ~terminal_effect_settled
  =
  List.filter_map
    (fun (applies, reason) -> if applies then Some reason else None)
    [ control_checkpoint, Control_checkpoint
    ; terminal_effect_settled, Terminal_effect_settled
    ]
;;

let wire_capture_response_suppression_reason_label = function
  | Control_checkpoint -> "control_checkpoint"
  | Terminal_effect_settled -> "terminal_effect_settled"
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

let is_trailing_blank_assistant (message : Agent_core.Types.message) =
  match message.role, message.content with
  | Agent_core.Types.Assistant, [] -> true
  | Agent_core.Types.Assistant, blocks ->
    List.for_all
      (function
        | Agent_core.Types.Text text -> String.trim text = ""
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

(* An internal turn earns a place in replay by what it did, not by what it
   said. A ToolUse/ToolResult anywhere in the suffix is that record; its
   absence means the turn produced only the wake cue and its own note. Reads
   the typed block, never the text. *)
let suffix_records_tool_activity (messages : Agent_core.Types.message list) =
  List.exists
    (fun (message : Agent_core.Types.message) ->
       List.exists
         (function
           | Agent_core.Types.ToolUse _ | Agent_core.Types.ToolResult _ -> true
           | _ -> false)
         message.Agent_core.Types.content)
    messages
;;

let drop_trailing_assistants messages =
  let rec drop dropped = function
    | ({ Agent_core.Types.role = Agent_core.Types.Assistant; _ } :
        Agent_core.Types.message)
      :: rest ->
      drop true rest
    | reversed -> List.rev reversed, dropped
  in
  drop false (List.rev messages)
;;

let canonical_success_replay_checkpoint
      ~(history_messages : Agent_core.Types.message list)
      ~(session_id : string)
      ~(response_text : string)
      ~suppress_visible_response
      ~exclude_thought_from_replay
      (checkpoint : Agent_core.Checkpoint.t)
  =
  match
    Keeper_replay_prefix.split
      ~prefix:history_messages
      checkpoint.Agent_core.Checkpoint.messages
  with
  | Ok current_suffix ->
       (* A blank visible response is not authority to erase typed replay. The
          suffix may contain an actual user input, ToolUse/ToolResult pair,
          thinking, or media whose effect has already happened. Ordinary blank
          completion removes only an inert trailing Assistant shell. A typed
          terminal-effect receipt is stronger: the external post is already the
          visible result, so its trailing provider Assistant response is not
          durable conversation. An internal turn reaches the same place from
          the other side: RFC-0385 gives its wake cue and final text no place
          in conversation, so a turn that called a tool keeps the call and its
          result while the note is dropped, and a turn that called nothing
          leaves the replay exactly as it found it. Every path preserves the
          preceding typed replay nodes. *)
       let current_suffix, replay_suffix_pruned =
         if suppress_visible_response
         then
           let current_suffix, assistant_dropped =
             drop_trailing_assistants current_suffix
           in
           ( current_suffix
           , if assistant_dropped
             then Some Suppressed_terminal_effect_response
             else None )
         else if exclude_thought_from_replay
         then
           if suffix_records_tool_activity current_suffix
           then
             let current_suffix, assistant_dropped =
               drop_trailing_assistants current_suffix
             in
             ( current_suffix
             , if assistant_dropped
               then Some Internal_thought_not_replayed
               else None )
           else
             ( []
             , match current_suffix with
               | [] -> None
               | _ :: _ -> Some Internal_turn_not_replayed )
         else if String.trim response_text = ""
         then
           let current_suffix, blank_assistant_dropped =
             drop_trailing_blank_assistants current_suffix
           in
           ( current_suffix
           , if blank_assistant_dropped
             then Some Canonical_success_replay
             else None )
         else current_suffix, None
       in
       let replay_omits_response =
         suppress_visible_response
         || exclude_thought_from_replay
         || String.trim response_text = ""
       in
       let checkpoint =
         if replay_omits_response
         then
           { checkpoint with
             Agent_core.Checkpoint.session_id
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
                 (fun (msg : Agent_core.Types.message) ->
                    msg.role = Agent_core.Types.Assistant)
                 current_suffix
             then base_messages
             else
               base_messages
               @
               [ Agent_core.Types.make_message
                   ~role:Agent_core.Types.Assistant
                   [ Agent_core.Types.Text response_text ]
               ]
           in
           Keeper_context_core.patch_checkpoint_last_assistant
             { checkpoint with Agent_core.Checkpoint.messages }
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
      ~(history_messages : Agent_core.Types.message list)
      ~(session_id : string)
      (checkpoint : Agent_core.Checkpoint.t)
  =
  match
    Keeper_replay_prefix.split
      ~prefix:history_messages
      checkpoint.Agent_core.Checkpoint.messages
  with
  | Ok _ ->
    Ok
      ( { checkpoint with
          Agent_core.Checkpoint.session_id
        }
      , None )
  | Error _ ->
    Error
      "refusing to save execution-observation checkpoint: messages do not match pre-turn history prefix"
;;

let checkpoint_for_replay_persistence
      ~(history_messages : Agent_core.Types.message list)
      ~(session_id : string)
      ~(response_text : string)
      ?(suppress_visible_response = false)
      ?(stop_reason = Runtime_agent.Completed)
      ~exclude_thought_from_replay
      (checkpoint : Agent_core.Checkpoint.t)
  =
  match stop_reason with
  | Runtime_agent.InputRequired _ ->
    (* The elicitation request can follow a current-turn tool result. Blank
       response canonicalization and completion-contract pruning must not
       remove that suffix; prefix validation still fails closed. *)
    (match
       Keeper_replay_prefix.split
         ~prefix:history_messages
         checkpoint.Agent_core.Checkpoint.messages
     with
     | Ok (_ :: _) ->
       Ok
         ( { checkpoint with
             Agent_core.Checkpoint.session_id
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
  | Runtime_agent.Yielded_to_operation_queued _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Yielded_after_repeated_tool_call _
  | Runtime_agent.Yielded_after_repeated_assistant_text _ ->
    (* A control-boundary checkpoint retains the current-turn tool result so
       resumption cannot repeat an already committed effect. *)
    observation_replay_checkpoint ~history_messages ~session_id checkpoint
  | Runtime_agent.Completed ->
    canonical_success_replay_checkpoint
      ~history_messages
      ~session_id
      ~response_text
      ~suppress_visible_response
      ~exclude_thought_from_replay
      checkpoint
;;

(* AGENT_CORE constructs the mutation-boundary checkpoint and then installs the same
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
    ~(last_persisted_checkpoint : Agent_core.Checkpoint.t option)
    (result_checkpoint : Agent_core.Checkpoint.t) =
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
    ~(source : Agent_core.Checkpoint.t)
    ~(patched : Agent_core.Checkpoint.t)
    ~replay_suffix_pruned =
  source_already_persisted
  && Option.is_none replay_suffix_pruned
  && String.equal source.session_id patched.session_id
  && source.messages == patched.messages
  && source.working_context == patched.working_context
;;
