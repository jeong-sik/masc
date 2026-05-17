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
