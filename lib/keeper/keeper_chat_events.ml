type role = User | Assistant

type stream_protocol_error_kind =
  | Tool_start_duplicate_index
  | Tool_start_missing_identity
  | Tool_args_without_start
  | Tool_stop_without_start
  | Tool_replay_mismatch
  | Tool_delta_invalid_kind
  | Tool_attempt_superseded
  | Tool_message_start_conflict
  | Stream_event_after_terminal
  | Tool_occurrence_mapping_invalid
  | Media_delta_invalid_block
  | Media_source_unsupported
  | Media_decode_failed
  | Media_payload_too_large
  | Media_persist_failed
  | Sse_error
  | Ndjson_error
  | Sse_parse_failed
  | Ndjson_parse_failed
  | Sse_unknown_event_type
  | Sse_unsupported_part
  | Sse_unsupported_response
  | Sse_stream_incomplete
  | Sse_stream_repeating

type runtime_attempt_scope_disposition =
  | Preserve_previous_scope
  | Abandon_previous_scope

type tool_stream_occurrence =
  { stream_scope : int
  ; provider_message_id : string option
  ; block_index : int
  }

type stream_protocol_error = {
  kind : stream_protocol_error_kind;
  quarantined_occurrence : tool_stream_occurrence option;
  index : int option;
  tool_call_id : string option;
  event_type : string option;
  reason : string option;
  raw_bytes : int option;
}

type reply_details =
  { reply : string
  ; turn_outcome : Keeper_turn_outcome.t
  ; turn_ref : Ids.Turn_ref.t
  }

type continuation_checkpoint =
  { message : string
  ; request_id : string option
  }

type keeper_chat_event =
  | Run_started of { run_id : string; thread_id : string }
  | Text_message_start of { message_id : string; role : role }
  | Text_delta of string
  | Text_message_end
  | External_effect_completed of
      { target : Keeper_surface_post.delivery_target }
  | Run_finished of { run_id : string }
  | Event_error of { message : string }
  | Reply_details of reply_details
  | Continuation_checkpoint of continuation_checkpoint
  | Agent_core_stream_connected
  | Agent_core_runtime_attempt_started
  | Agent_core_stream_message_start of
      { provider_message_id : string
      ; model : string
      ; usage : Agent_core.Types.api_usage option
      }
  | Agent_core_stream_message_delta of
      { stop_reason : Agent_core.Types.stop_reason option
      ; usage : Agent_core.Types.delta_usage option
      }
  | Agent_core_stream_message_stop
  | Agent_core_stream_ping
  | Agent_core_content_block_start of
      { index : int
      ; content_type : string
      ; tool_call_id : string option
      ; tool_call_name : string option
      }
  | Agent_core_content_block_stop of { index : int }
  | Agent_core_thinking_delta of { index : int; delta : string }
  | Agent_core_thinking_signature_delta of { index : int; signature_bytes : int }
  | Agent_core_media_delta of
      { index : int
      ; media_type : string
      ; source_type : Agent_core.Types.media_source_kind
      ; media_ref : string
          (* RFC-0301: reader-facing URL of the persisted media
             ([/api/v1/media/<token>], via Keeper_chat_media_store), replacing the
             pre-RFC byte count. The data channel carries the reference to the
             actual payload, not a telemetry count. *)
      }
  | Agent_core_stream_protocol_error of stream_protocol_error
  | Tool_call_start of
      { occurrence : tool_stream_occurrence
      ; tool_call_id : string option
      ; tool_call_name : string
      }
  | Tool_call_args of
      { occurrence : tool_stream_occurrence
      ; tool_call_id : string option
      ; delta : string
      }
  | Tool_call_args_snapshot of
      { occurrence : tool_stream_occurrence
      ; tool_call_id : string option
      ; snapshot : string
      }
  | Tool_call_end of
      { occurrence : tool_stream_occurrence
      ; tool_call_id : string option
      }
  | Tool_approval_requested of
      { tool_call_id : string
      ; tool_call_name : string
      ; args : string
      ; question : string
      ; because : string
      }
  | Tool_approval_settled of
      { tool_call_id : string
      ; outcome : string
      }
  | Tool_result_ready of
      { occurrence : tool_stream_occurrence
      ; tool_call_id : string option
      ; execution_id : Ids.Execution_id.t
      }
  | Link_block of
      { url : string
      ; title : string
      ; description : string option
      ; image : string option
      }
  | Image_block of { url : string; caption : string option }
  | Status_block of Keeper_chat_blocks.status_block
  | Audio_block of
      { token : string
      ; mime : string
      ; message_text : string
      ; duration_sec : float option
      }
  | Tool_context_block of
      { tool_call_id : string
      ; name : string
      ; args_summary : string
      ; result_summary : string option
      }

type published =
  { seq : int
  ; ts : float
  ; event : keeper_chat_event
  }

type t =
  { stream : published Eio.Stream.t
  ; on_publish : (seq:int -> ts:float -> keeper_chat_event -> unit) option
  ; now : unit -> float
  ; mutable next_seq : int
  }

let create ?(now = Time_compat.now) ?on_publish () =
  { stream = Eio.Stream.create 512; on_publish; now; next_seq = 0 }
;;

(* [publish] is the single choke point every turn event passes through — route
   lifecycle, bridge-translated deltas, and terminal paths all call it. The
   hook runs BEFORE the bus add so the canonical journal records what the turn
   produced even when a full bus suspends the add. The ordering guarantee rests
   on one invariant: every [publish] for a given bus runs in the single
   publisher fiber (the process_single_turn / consume_worker_events call tree
   in server_routes_http_keeper_stream.ml), so seq assignment → hook → bus add
   executes sequentially within that fiber and journal order == seq order ==
   bus order with no extra lock. The journal hook's blocking Unix I/O is
   offloaded via Fs_compat.run_blocking_private_file_transaction
   (Eio_unix.run_in_systhread when called from an Eio fiber), which suspends
   only the calling fiber — that keeps sibling fibers responsive but is not
   what makes the ordering safe. *)
let publish t event =
  let seq = t.next_seq in
  t.next_seq <- seq + 1;
  (* One clock reading per event. The journal line and every live projection
     of this event carry this same [ts], which is what lets a replay from the
     journal reproduce the live frames byte for byte. A raising clock falls
     back to the real one rather than breaking the turn. *)
  let ts =
    try t.now () with
    | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
    | exn ->
      Log.Keeper.error
        "keeper_chat_events: clock raised seq=%d: %s; falling back to Time_compat.now"
        seq
        (Printexc.to_string exn);
      Time_compat.now ()
  in
  (match t.on_publish with
   | None -> ()
   | Some hook ->
     (try hook ~seq ~ts event with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.Keeper.error
          "keeper_chat_events: on_publish hook failed seq=%d: %s"
          seq
          (Printexc.to_string exn)));
  Eio.Stream.add t.stream { seq; ts; event }
;;

let subscribe t = (Eio.Stream.take t.stream).event
let subscribe_published t = Eio.Stream.take t.stream

let take_nonblocking t =
  Option.map (fun published -> published.event) (Eio.Stream.take_nonblocking t.stream)
;;

let json_opt key value =
  match value with
  | None -> []
  | Some value -> [ (key, value) ]

let api_usage_to_json (usage : Agent_core.Types.api_usage) =
  `Assoc
    ([
       ("input_tokens", `Int usage.input_tokens);
       ("output_tokens", `Int usage.output_tokens);
       ("total_tokens", `Int (Agent_core.Types.total_tokens usage));
       ("cache_creation_input_tokens", `Int usage.cache_creation_input_tokens);
       ("cache_read_input_tokens", `Int usage.cache_read_input_tokens);
     ]
     @ json_opt "cost_usd"
         (Option.map (fun value -> `Float value) usage.cost_usd))

(* Cumulative mid-stream counters: only the fields the delta actually
   reported appear, so a reader can tell "not reported" from 0. *)
let delta_usage_to_json (usage : Agent_core.Types.delta_usage) =
  `Assoc
    (json_opt "input_tokens" (Option.map (fun v -> `Int v) usage.input_tokens)
    @ json_opt "output_tokens" (Option.map (fun v -> `Int v) usage.output_tokens)
    @ json_opt "cache_creation_input_tokens"
        (Option.map (fun v -> `Int v) usage.cache_creation_input_tokens)
    @ json_opt "cache_read_input_tokens"
        (Option.map (fun v -> `Int v) usage.cache_read_input_tokens))

let stream_protocol_error_kind_to_string = function
  | Tool_start_duplicate_index -> "tool_start_duplicate_index"
  | Tool_start_missing_identity -> "tool_start_missing_identity"
  | Tool_args_without_start -> "tool_args_without_start"
  | Tool_stop_without_start -> "tool_stop_without_start"
  | Tool_replay_mismatch -> "tool_replay_mismatch"
  | Tool_delta_invalid_kind -> "tool_delta_invalid_kind"
  | Tool_attempt_superseded -> "tool_attempt_superseded"
  | Tool_message_start_conflict -> "tool_message_start_conflict"
  | Stream_event_after_terminal -> "stream_event_after_terminal"
  | Tool_occurrence_mapping_invalid -> "tool_occurrence_mapping_invalid"
  | Media_delta_invalid_block -> "media_delta_invalid_block"
  | Media_source_unsupported -> "media_source_unsupported"
  | Media_decode_failed -> "media_decode_failed"
  | Media_payload_too_large -> "media_payload_too_large"
  | Media_persist_failed -> "media_persist_failed"
  | Sse_error -> "sse_error"
  | Ndjson_error -> "ndjson_error"
  | Sse_parse_failed -> "sse_parse_failed"
  | Ndjson_parse_failed -> "ndjson_parse_failed"
  | Sse_unknown_event_type -> "sse_unknown_event_type"
  | Sse_unsupported_part -> "sse_unsupported_part"
  | Sse_unsupported_response -> "sse_unsupported_response"
  | Sse_stream_incomplete -> "sse_stream_incomplete"
  | Sse_stream_repeating -> "sse_stream_repeating"

let stream_protocol_error_kind_of_string = function
  | "tool_start_duplicate_index" -> Some Tool_start_duplicate_index
  | "tool_start_missing_identity" -> Some Tool_start_missing_identity
  | "tool_args_without_start" -> Some Tool_args_without_start
  | "tool_stop_without_start" -> Some Tool_stop_without_start
  | "tool_replay_mismatch" -> Some Tool_replay_mismatch
  | "tool_delta_invalid_kind" -> Some Tool_delta_invalid_kind
  | "tool_attempt_superseded" -> Some Tool_attempt_superseded
  | "tool_message_start_conflict" -> Some Tool_message_start_conflict
  | "stream_event_after_terminal" -> Some Stream_event_after_terminal
  | "tool_occurrence_mapping_invalid" -> Some Tool_occurrence_mapping_invalid
  | "media_delta_invalid_block" -> Some Media_delta_invalid_block
  | "media_source_unsupported" -> Some Media_source_unsupported
  | "media_decode_failed" -> Some Media_decode_failed
  | "media_payload_too_large" -> Some Media_payload_too_large
  | "media_persist_failed" -> Some Media_persist_failed
  | "sse_error" -> Some Sse_error
  | "ndjson_error" -> Some Ndjson_error
  | "sse_parse_failed" -> Some Sse_parse_failed
  | "ndjson_parse_failed" -> Some Ndjson_parse_failed
  | "sse_unknown_event_type" -> Some Sse_unknown_event_type
  | "sse_unsupported_part" -> Some Sse_unsupported_part
  | "sse_unsupported_response" -> Some Sse_unsupported_response
  | "sse_stream_incomplete" -> Some Sse_stream_incomplete
  | "sse_stream_repeating" -> Some Sse_stream_repeating
  | _ -> None

let stream_protocol_error_summary error =
  let parts =
    [
      Some (stream_protocol_error_kind_to_string error.kind);
      Option.map
        (fun occurrence ->
           Printf.sprintf "quarantined_occurrence=%d/%d"
             occurrence.stream_scope occurrence.block_index)
        error.quarantined_occurrence;
      Option.map (Printf.sprintf "index=%d") error.index;
      Option.map (Printf.sprintf "tool_call_id=%s") error.tool_call_id;
      Option.map (Printf.sprintf "event_type=%s") error.event_type;
      error.reason;
      Option.map (Printf.sprintf "raw_bytes=%d") error.raw_bytes;
    ]
    |> List.filter_map Fun.id
  in
  String.concat " | " parts

let stream_protocol_error_to_json error =
  let quarantined_occurrence =
    Option.map
      (fun occurrence ->
         `Assoc
           ([ "toolStreamScope", `Int occurrence.stream_scope
            ; "toolCallBlockIndex", `Int occurrence.block_index
            ]
            @ json_opt "providerMessageId"
                (Option.map
                   (fun value -> `String value)
                   occurrence.provider_message_id)))
      error.quarantined_occurrence
  in
  let fields =
    [
      ( "kind",
        `String (stream_protocol_error_kind_to_string error.kind) );
    ]
    @ json_opt "quarantined_occurrence" quarantined_occurrence
    @ json_opt "index" (Option.map (fun value -> `Int value) error.index)
    @ json_opt "tool_call_id"
        (Option.map (fun value -> `String value) error.tool_call_id)
    @ json_opt "event_type"
        (Option.map (fun value -> `String value) error.event_type)
    @ json_opt "reason" (Option.map (fun value -> `String value) error.reason)
    @ json_opt "raw_bytes" (Option.map (fun value -> `Int value) error.raw_bytes)
  in
  `Assoc fields
