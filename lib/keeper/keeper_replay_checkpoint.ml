(** Canonical replay checkpoint projection and response-capture policy. *)

type replay_suffix_prune_reason = Keeper_checkpoint_replay_projection.replay_suffix_prune_reason
let replay_suffix_prune_reason_to_string =
  Keeper_checkpoint_replay_projection.replay_suffix_prune_reason_to_string
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

let checkpoint_for_replay_persistence =
  Keeper_checkpoint_replay_projection.checkpoint_for_replay_persistence
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

(* Message identity avoids re-encoding the transcript, but says nothing about
   Context, usage, tools or the next invocation's configuration. Compare the
   remaining checkpoint schema through its owning codec so a new schema field
   cannot silently fall outside this reuse decision. Creation time records the
   snapshot operation, not a change to replay state. *)
let same_replay_state_metadata
    (left : Agent_core.Checkpoint.t)
    (right : Agent_core.Checkpoint.t) =
  let metadata checkpoint =
    Agent_core.Checkpoint.to_json_result
      { checkpoint with messages = []; created_at = 0. }
  in
  match metadata left, metadata right with
  | Ok left, Ok right -> Yojson.Safe.equal left right
  | Error _, _ | _, Error _ -> false
;;

let select_finalization_checkpoint
    ~(last_persisted_checkpoint : Agent_core.Checkpoint.t option)
    (result_checkpoint : Agent_core.Checkpoint.t) =
  match last_persisted_checkpoint with
  | Some persisted
    when Int.equal persisted.turn_count result_checkpoint.turn_count
         && messages_share_values_by_identity
              persisted.messages
              result_checkpoint.messages
         && same_replay_state_metadata persisted result_checkpoint ->
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
  && same_replay_state_metadata source patched
;;
