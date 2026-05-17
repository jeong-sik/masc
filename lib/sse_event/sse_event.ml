(* RFC-0004 Phase A0.1 PR-1 — typed SSE event wrapper.

   Bridges atd-generated payload types (see [Sse_event_t],
   [Sse_event_j]) and the manual envelope wrap that replicates
   [lib/cascade/cascade_event_bridge.wrap_event] (lines 507-531) +
   [json_string_opt] (lines 25-27) semantics.

   The envelope is intentionally hand-rolled in OCaml rather than
   declared in atd because [json_string_opt] coerces [Some ""] to
   [`Null] — atd's default nullable maps [Some ""] to [""]. A custom
   atd JSON adapter could close the gap; PR-1 keeps the envelope
   manual to ship the first event with zero adapter risk. *)

(** Envelope metadata fields common to every SSE event.

    Field semantics match [cascade_event_bridge.wrap_event]: optional
    string fields use [json_string_opt] (empty string → null), and
    [turn] uses plain [option fold] (None → null). *)
type envelope_meta =
  { event_type : string
  ; ts_unix : float
  ; correlation_id : string
  ; run_id : string
  ; agent_name : string option
  ; task_id : string option
  ; turn : int option
  ; tool_name : string option
  }

(** Replicates [cascade_event_bridge.json_string_opt]:

    - [Some "non-empty"] → [`String value]
    - [Some "" \| Some "<whitespace>"] → [`Null]
    - [None] → [`Null] *)
let json_string_opt = function
  | Some value when String.trim value <> "" -> `String value
  | _ -> `Null
;;

(** Wrap a typed payload with the standard envelope.  Returns the
    same field shape and order as [wrap_event] so its output is
    byte-identical when serialized via [Yojson.Safe.to_string]. *)
let wrap_envelope (meta : envelope_meta) (payload : Yojson.Safe.t) : Yojson.Safe.t =
  `Assoc
    [ "type", `String ("oas:" ^ meta.event_type)
    ; "event_type", `String meta.event_type
    ; "ts_unix", `Float meta.ts_unix
    ; "correlation_id", `String meta.correlation_id
    ; "run_id", `String meta.run_id
    ; "agent_name", json_string_opt meta.agent_name
    ; "task_id", json_string_opt meta.task_id
    ; ( "turn"
      , Option.fold ~none:`Null ~some:(fun value -> `Int value) meta.turn )
    ; "tool_name", json_string_opt meta.tool_name
    ; "payload", payload
    ]
;;

(** Emit a full [agent_started] envelope as JSON.

    [agent_name] and [task_id] in the envelope are populated from the
    same values as the payload — this matches the
    [cascade_event_bridge] AgentStarted arm at lines 556-560 which
    passes [~agent_name ~task_id] to [wrap_event] alongside the
    payload [`Assoc]. *)
let agent_started
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(agent_name : string)
      ~(task_id : string)
  : Yojson.Safe.t
  =
  let payload_json =
    let p : Sse_event_t.agent_started_payload = { agent_name; task_id } in
    Yojson.Safe.from_string (Sse_event_j.string_of_agent_started_payload p)
  in
  wrap_envelope
    { event_type = "agent_started"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; agent_name = Some agent_name
    ; task_id = Some task_id
    ; turn = None
    ; tool_name = None
    }
    payload_json
;;

(** Emit a [tool_called] envelope.  Matches cascade arm at
    lib/cascade/cascade_event_bridge.ml:599-603 (pre-PR-3): envelope
    populates ~agent_name ~tool_name; payload mirrors the same two
    fields. *)
let tool_called
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(agent_name : string)
      ~(tool_name : string)
  : Yojson.Safe.t
  =
  let payload_json =
    let p : Sse_event_t.tool_called_payload = { agent_name; tool_name } in
    Yojson.Safe.from_string (Sse_event_j.string_of_tool_called_payload p)
  in
  wrap_envelope
    { event_type = "tool_called"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; agent_name = Some agent_name
    ; task_id = None
    ; turn = None
    ; tool_name = Some tool_name
    }
    payload_json
;;

(** Emit a [tool_completed] envelope.  Same shape as [tool_called]. *)
let tool_completed
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(agent_name : string)
      ~(tool_name : string)
  : Yojson.Safe.t
  =
  let payload_json =
    let p : Sse_event_t.tool_completed_payload = { agent_name; tool_name } in
    Yojson.Safe.from_string (Sse_event_j.string_of_tool_completed_payload p)
  in
  wrap_envelope
    { event_type = "tool_completed"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; agent_name = Some agent_name
    ; task_id = None
    ; turn = None
    ; tool_name = Some tool_name
    }
    payload_json
;;

(** Emit a [turn_started] envelope. *)
let turn_started
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(agent_name : string)
      ~(turn : int)
  : Yojson.Safe.t
  =
  let payload_json =
    let p : Sse_event_t.turn_started_payload = { agent_name; turn } in
    Yojson.Safe.from_string (Sse_event_j.string_of_turn_started_payload p)
  in
  wrap_envelope
    { event_type = "turn_started"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; agent_name = Some agent_name
    ; task_id = None
    ; turn = Some turn
    ; tool_name = None
    }
    payload_json
;;

(** Emit a [turn_completed] envelope. *)
let turn_completed
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(agent_name : string)
      ~(turn : int)
  : Yojson.Safe.t
  =
  let payload_json =
    let p : Sse_event_t.turn_completed_payload = { agent_name; turn } in
    Yojson.Safe.from_string (Sse_event_j.string_of_turn_completed_payload p)
  in
  wrap_envelope
    { event_type = "turn_completed"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; agent_name = Some agent_name
    ; task_id = None
    ; turn = Some turn
    ; tool_name = None
    }
    payload_json
;;

(** Emit a [turn_ready] envelope.  The wrapper computes [count] from
    [List.length tool_names] and [names_hash] as the first 16 chars
    of [Digest.to_hex (Digest.string (String.concat "\n" tool_names))],
    matching cascade arm at cascade_event_bridge.ml:615-624 (pre-PR-3). *)
let turn_ready
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(agent_name : string)
      ~(turn : int)
      ~(tool_names : string list)
  : Yojson.Safe.t
  =
  let names_hash =
    Digest.to_hex (Digest.string (String.concat "\n" tool_names))
  in
  let payload_json =
    let p : Sse_event_t.turn_ready_payload =
      { agent_name
      ; turn
      ; count = List.length tool_names
      ; names_hash = String.sub names_hash 0 16
      ; tool_names
      }
    in
    Yojson.Safe.from_string (Sse_event_j.string_of_turn_ready_payload p)
  in
  wrap_envelope
    { event_type = "turn_ready"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; agent_name = Some agent_name
    ; task_id = None
    ; turn = Some turn
    ; tool_name = None
    }
    payload_json
;;

(** Emit a [handoff_requested] envelope.  Envelope [agent_name] mirrors
    the [from_agent] field, matching cascade arm at lines 641-649. *)
let handoff_requested
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(from_agent : string)
      ~(to_agent : string)
      ~(reason : string)
  : Yojson.Safe.t
  =
  let payload_json =
    let p : Sse_event_t.handoff_requested_payload =
      { from_agent; to_agent; reason }
    in
    Yojson.Safe.from_string (Sse_event_j.string_of_handoff_requested_payload p)
  in
  wrap_envelope
    { event_type = "handoff_requested"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; agent_name = Some from_agent
    ; task_id = None
    ; turn = None
    ; tool_name = None
    }
    payload_json
;;

(** Emit a [handoff_completed] envelope. *)
let handoff_completed
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(from_agent : string)
      ~(to_agent : string)
      ~(elapsed_s : float)
  : Yojson.Safe.t
  =
  let payload_json =
    let p : Sse_event_t.handoff_completed_payload =
      { from_agent; to_agent; elapsed_s }
    in
    Yojson.Safe.from_string (Sse_event_j.string_of_handoff_completed_payload p)
  in
  wrap_envelope
    { event_type = "handoff_completed"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; agent_name = Some from_agent
    ; task_id = None
    ; turn = None
    ; tool_name = None
    }
    payload_json
;;

(** Emit a [context_compacted] envelope.  Cascade-side side effect
    (Context_overflow_action_tracker.record_action) is retained in the
    cascade arm and runs before this constructor. *)
let context_compacted
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(agent_name : string)
      ~(before_tokens : int)
      ~(after_tokens : int)
      ~(phase : string)
  : Yojson.Safe.t
  =
  let payload_json =
    let p : Sse_event_t.context_compacted_payload =
      { agent_name; before_tokens; after_tokens; phase }
    in
    Yojson.Safe.from_string (Sse_event_j.string_of_context_compacted_payload p)
  in
  wrap_envelope
    { event_type = "context_compacted"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; agent_name = Some agent_name
    ; task_id = None
    ; turn = None
    ; tool_name = None
    }
    payload_json
;;

(** Emit a [context_overflow_imminent] envelope.  Prometheus gauge +
    tracker side effects stay in the cascade arm. *)
let context_overflow_imminent
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(agent_name : string)
      ~(estimated_tokens : int)
      ~(limit_tokens : int)
      ~(ratio : float)
  : Yojson.Safe.t
  =
  let payload_json =
    let p : Sse_event_t.context_overflow_imminent_payload =
      { agent_name; estimated_tokens; limit_tokens; ratio }
    in
    Yojson.Safe.from_string
      (Sse_event_j.string_of_context_overflow_imminent_payload p)
  in
  wrap_envelope
    { event_type = "context_overflow_imminent"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; agent_name = Some agent_name
    ; task_id = None
    ; turn = None
    ; tool_name = None
    }
    payload_json
;;

(** Emit a [context_compact_started] envelope. *)
let context_compact_started
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(agent_name : string)
      ~(trigger : string)
  : Yojson.Safe.t
  =
  let payload_json =
    let p : Sse_event_t.context_compact_started_payload =
      { agent_name; trigger }
    in
    Yojson.Safe.from_string
      (Sse_event_j.string_of_context_compact_started_payload p)
  in
  wrap_envelope
    { event_type = "context_compact_started"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; agent_name = Some agent_name
    ; task_id = None
    ; turn = None
    ; tool_name = None
    }
    payload_json
;;

(** Emit a [content_replacement_replaced] envelope.  Envelope
    [agent_name] is None, matching cascade arm at lines 708-717. *)
let content_replacement_replaced
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(tool_use_id : string)
      ~(preview : string)
      ~(original_chars : int)
      ~(seen_count_after : int)
  : Yojson.Safe.t
  =
  let payload_json =
    let p : Sse_event_t.content_replacement_replaced_payload =
      { tool_use_id; preview; original_chars; seen_count_after }
    in
    Yojson.Safe.from_string
      (Sse_event_j.string_of_content_replacement_replaced_payload p)
  in
  wrap_envelope
    { event_type = "content_replacement_replaced"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; agent_name = None
    ; task_id = None
    ; turn = None
    ; tool_name = None
    }
    payload_json
;;

(** Emit a [content_replacement_kept] envelope. *)
let content_replacement_kept
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(tool_use_id : string)
      ~(seen_count_after : int)
  : Yojson.Safe.t
  =
  let payload_json =
    let p : Sse_event_t.content_replacement_kept_payload =
      { tool_use_id; seen_count_after }
    in
    Yojson.Safe.from_string
      (Sse_event_j.string_of_content_replacement_kept_payload p)
  in
  wrap_envelope
    { event_type = "content_replacement_kept"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; agent_name = None
    ; task_id = None
    ; turn = None
    ; tool_name = None
    }
    payload_json
;;

(** Emit a [slot_scheduler_observed] envelope.  The [state] variant
    (Idle/Queued/Saturated) is stringified by the cascade arm before
    invocation. *)
let slot_scheduler_observed
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(max_slots : int)
      ~(active : int)
      ~(available : int)
      ~(queue_length : int)
      ~(state : string)
  : Yojson.Safe.t
  =
  let payload_json =
    let p : Sse_event_t.slot_scheduler_observed_payload =
      { max_slots; active; available; queue_length; state }
    in
    Yojson.Safe.from_string
      (Sse_event_j.string_of_slot_scheduler_observed_payload p)
  in
  wrap_envelope
    { event_type = "slot_scheduler_observed"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; agent_name = None
    ; task_id = None
    ; turn = None
    ; tool_name = None
    }
    payload_json
;;
