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

let patch_checkpoint_last_assistant
    (cp : Agent_core.Checkpoint.t) ~session_id ~response_text
  : Agent_core.Checkpoint.t =
  let visible_response_text = response_text in
  let patch_assistant_message (msg : Agent_core.Types.message) =
    let visible_is_blank = String.trim visible_response_text = "" in
    let rec patch_content replaced acc = function
      | [] ->
          if replaced || visible_is_blank then List.rev acc
          else List.rev (Agent_core.Types.Text visible_response_text :: acc)
      | Agent_core.Types.Text _ :: rest when not replaced ->
          let acc =
            if visible_is_blank then acc
            else Agent_core.Types.Text visible_response_text :: acc
          in
          patch_content true acc rest
      | Agent_core.Types.Text _ :: rest -> patch_content replaced acc rest
      | (Agent_core.Types.Thinking _
         | Agent_core.Types.ReasoningDetails _
         | Agent_core.Types.RedactedThinking _
         | Agent_core.Types.ToolUse _
         | Agent_core.Types.ToolResult _
         | Agent_core.Types.Image _
         | Agent_core.Types.Document _
         | Agent_core.Types.Audio _ as block) :: rest ->
          patch_content replaced (block :: acc) rest
    in
    let content =
      if List.mem_assoc Agent_core.Types.Response_replay.metadata_key msg.metadata
      then msg.Agent_core.Types.content
      else patch_content false [] msg.Agent_core.Types.content
    in
    let rec content_unchanged left right =
      match left, right with
      | [], [] -> true
      | Agent_core.Types.Text left :: left_rest,
        Agent_core.Types.Text right :: right_rest
        when String.equal left right ->
        content_unchanged left_rest right_rest
      | left_block :: left_rest, right_block :: right_rest
        when left_block == right_block ->
        content_unchanged left_rest right_rest
      | [], _ :: _ | _ :: _, [] -> false
      | ( Agent_core.Types.Text _
        | Agent_core.Types.Thinking _
        | Agent_core.Types.ReasoningDetails _
        | Agent_core.Types.RedactedThinking _
        | Agent_core.Types.ToolUse _
        | Agent_core.Types.ToolResult _
        | Agent_core.Types.Image _
        | Agent_core.Types.Document _
        | Agent_core.Types.Audio _ ) :: _
      , ( Agent_core.Types.Text _
        | Agent_core.Types.Thinking _
        | Agent_core.Types.ReasoningDetails _
        | Agent_core.Types.RedactedThinking _
        | Agent_core.Types.ToolUse _
        | Agent_core.Types.ToolResult _
        | Agent_core.Types.Image _
        | Agent_core.Types.Document _
        | Agent_core.Types.Audio _ ) :: _ -> false
    in
    if content_unchanged content msg.Agent_core.Types.content
       && Option.is_none msg.name
       && Option.is_none msg.tool_call_id
    then msg
    else
      (* The reconstruction keeps metadata only: name/tool_call_id stay
         dropped because assistant messages never carry them in practice. *)
      Agent_core.Types.make_message
        ~metadata:msg.metadata
        ~role:Agent_core.Types.Assistant
        content
  in
  let rec patch_last_assistant suffix_rev = function
    | [] -> cp.messages
    | msg :: older_rev when msg.Agent_core.Types.role = Agent_core.Types.Assistant ->
        let patched = patch_assistant_message msg in
        if patched == msg
        then cp.messages
        else List.rev_append older_rev (patched :: suffix_rev)
    | msg :: older_rev -> patch_last_assistant (msg :: suffix_rev) older_rev
  in
  let messages =
    patch_last_assistant [] (List.rev cp.messages)
  in
  { cp with Agent_core.Checkpoint.session_id;
            messages;
            working_context = None }

;;

let is_trailing_blank_assistant (message : Agent_core.Types.message) =
  match message.role, message.content with
  | Agent_core.Types.Assistant, [] -> true
  | Agent_core.Types.Assistant, blocks ->
    List.for_all
      (function
        | Agent_core.Types.Text text -> String.trim text = ""
        | Agent_core.Types.Thinking _ | Agent_core.Types.ReasoningDetails _
        | Agent_core.Types.RedactedThinking _ | Agent_core.Types.ToolUse _
        | Agent_core.Types.ToolResult _ | Agent_core.Types.Image _ | Agent_core.Types.Document _
        | Agent_core.Types.Audio _ -> false)
      blocks
  | (Agent_core.Types.System, _) | (Agent_core.Types.User, _) | (Agent_core.Types.Tool, _) -> false
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
           | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
           | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
           | Agent_core.Types.Image _ | Agent_core.Types.Document _ | Agent_core.Types.Audio _ -> false)
         message.Agent_core.Types.content)
    messages
;;

let drop_trailing_assistants messages =
  let retained_context (message : Agent_core.Types.message) =
    match Agent_core.Types.Extra_system_context_provenance.classify message.metadata with
    | Historical -> true
    | Absent | Present | Invalid | Duplicate -> false
  in
  let rec drop dropped = function
    | ({ Agent_core.Types.role = Agent_core.Types.Assistant; _ } :
        Agent_core.Types.message)
      :: rest ->
      (* Collection stored this context immediately before the response whose
         signed reasoning needed it. Once that response is excluded from
         replay, its context must not survive as a standalone User message.
         Never consume an ordinary input or context belonging to an earlier
         retained response. *)
      let rest =
        match rest with
        | context :: rest when retained_context context -> rest
        | _ -> rest
      in
      drop true rest
    | ([]
      | { Agent_core.Types.role =
            ( Agent_core.Types.System | Agent_core.Types.User | Agent_core.Types.Tool )
        ; _
        }
        :: _) as reversed -> List.rev reversed, dropped
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
           patch_checkpoint_last_assistant
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

