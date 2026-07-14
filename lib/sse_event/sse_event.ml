(* RFC-0004 Phase A0.1 PR-1 — typed SSE event wrapper.

   Bridges atd-generated payload types (see [Sse_event_t],
   [Sse_event_j]) and the manual envelope wrap that replicates
   [lib/runtime/runtime_event_bridge.wrap_event] (lines 507-531) +
   [json_string_opt] (lines 25-27) semantics.

   The envelope is intentionally hand-rolled in OCaml rather than
   declared in atd because [json_string_opt] coerces [Some ""] to
   [`Null] — atd's default nullable maps [Some ""] to [""]. A custom
   atd JSON adapter could close the gap; PR-1 keeps the envelope
   manual to ship the first event with zero adapter risk. *)

(** Envelope metadata fields common to every SSE event.

    Field semantics match [runtime_event_bridge.wrap_event]: optional
    string fields use [json_string_opt] (empty string → null), and
    [turn] uses plain [option fold] (None → null). *)
type envelope_meta =
  { event_type : string
  ; ts_unix : float
  ; correlation_id : string
  ; run_id : string
  ; caused_by : string option
  ; agent_name : string option
  ; task_id : string option
  ; turn : int option
  ; tool_name : string option
  }

(** Replicates [runtime_event_bridge_inference.json_string_opt]:

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
    ; "caused_by", json_string_opt meta.caused_by
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
    [runtime_event_bridge] AgentStarted arm at lines 556-560 which
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
    ; caused_by = None
    ; agent_name = Some agent_name
    ; task_id = Some task_id
    ; turn = None
    ; tool_name = None
    }
    payload_json
;;

(** Emit a [tool_called] envelope.  Matches runtime arm at
    lib/runtime/runtime_event_bridge.ml:599-603 (pre-PR-3): envelope
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
    ; caused_by = None
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
    ; caused_by = None
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
    ; caused_by = None
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
    ; caused_by = None
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
    matching runtime arm at runtime_event_bridge.ml:615-624 (pre-PR-3). *)
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
    ; caused_by = None
    ; agent_name = Some agent_name
    ; task_id = None
    ; turn = Some turn
    ; tool_name = None
    }
    payload_json
;;

(** Emit a [handoff_requested] envelope.  Envelope [agent_name] mirrors
    the [from_agent] field, matching runtime arm at lines 641-649. *)
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
    ; caused_by = None
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
    ; caused_by = None
    ; agent_name = Some from_agent
    ; task_id = None
    ; turn = None
    ; tool_name = None
    }
    payload_json
;;

(** Append a caller-supplied addendum to an atd-emitted record JSON.

    Used by [agent_completed] and [agent_failed] to splice the
    runtime-local Result/Error projection ([result_fields] /
    [error_fields]) onto the typed base record without forcing the
    leaf event library to depend on [Agent_sdk] variant types.

    Field order is [<base record fields in atd declaration order> @
    <addendum>], which matches the previous inline `Assoc path in
    [runtime_event_bridge.ml] and is the property the byte-equal
    tests in [test_sse_event.ml] pin against. *)
let merge_addendum_into_record
      (record_json : Yojson.Safe.t)
      (addendum : (string * Yojson.Safe.t) list)
  : Yojson.Safe.t
  =
  match record_json with
  | `Assoc base -> `Assoc (base @ addendum)
  | _ ->
    invalid_arg
      "Sse_event.merge_addendum_into_record: atdgen record JSON must be `Assoc"
;;

(** Emit an [agent_completed] envelope.  The runtime arm in
    [runtime_event_bridge.ml] retains its [observe_inference_cost]
    side effect (Otel_metric_store histogram) and invokes
    [agent_completed_result_fields result] to project the
    [Agent_sdk] [Result.t] into the [result_fields] addendum. *)
let agent_completed
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(agent_name : string)
      ~(task_id : string)
      ~(elapsed_s : float)
      ~(result_fields : (string * Yojson.Safe.t) list)
  : Yojson.Safe.t
  =
  let base_json =
    let p : Sse_event_t.agent_completed_payload =
      { agent_name; task_id; elapsed_s }
    in
    Yojson.Safe.from_string (Sse_event_j.string_of_agent_completed_payload p)
  in
  let payload_json = merge_addendum_into_record base_json result_fields in
  wrap_envelope
    { event_type = "agent_completed"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; caused_by = None
    ; agent_name = Some agent_name
    ; task_id = Some task_id
    ; turn = None
    ; tool_name = None
    }
    payload_json
;;

(** Emit an [agent_failed] envelope.  All five error fields are
    encoded in the atd schema; the caller passes the simple
    projections directly. *)
let agent_failed
      ?caused_by
      ~(ts_unix : float)
      ~(correlation_id : string)
      ~(run_id : string)
      ~(agent_name : string)
      ~(task_id : string)
      ~(elapsed_s : float)
      ~(error : string)
      ~(error_domain : string)
      ~(error_code : string)
      ~(error_retryable : bool)
      ~(error_detail : Yojson.Safe.t)
      ()
  : Yojson.Safe.t
  =
  let payload_json =
    let p : Sse_event_t.agent_failed_payload =
      { agent_name
      ; task_id
      ; elapsed_s
      ; error
      ; error_domain
      ; error_code
      ; error_retryable
      ; error_detail
      }
    in
    Yojson.Safe.from_string (Sse_event_j.string_of_agent_failed_payload p)
  in
  wrap_envelope
    { event_type = "agent_failed"
    ; ts_unix
    ; correlation_id
    ; run_id
    ; caused_by
    ; agent_name = Some agent_name
    ; task_id = Some task_id
    ; turn = None
    ; tool_name = None
    }
    payload_json
;;
