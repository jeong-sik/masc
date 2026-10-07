(** Session push bridge: delivers a structured event to every active agent
    session's notification queue. *)

(** The push function [Mcp_server] installs at bootstrap, so agents can poll
    for an event without an SSE subscription. [None] until then. *)
let session_registry : (Yojson.Safe.t -> int) option Atomic.t = Atomic.make None

(** One-shot gate for the "registry not wired" message below. Keeps the
    log from flooding when callers on a hot path (Task.Tool,
    mcp_tool_runtime_comm) invoke push_event_to_sessions before
    bootstrap wires the bridge — or in test harnesses that never wire
    it at all. *)
let unwired_warned = Atomic.make false

let set_session_push_fn (fn : Yojson.Safe.t -> int) =
  (match Atomic.exchange session_registry (Some fn) with
   | Some _ -> Log.Sub.warn "WARNING: session push fn already set, overwriting"
   | None -> ());
  (* Reset the one-shot gate so a future explicit unwire would warn again. *)
  Atomic.set unwired_warned false

(** Push a structured event to all active agent sessions.
    Used by modules (e.g. Task.Tool) that lack direct Session.registry access. *)
let push_event_to_sessions (event : Yojson.Safe.t) : unit =
  match Atomic.get session_registry with
  | Some push_fn ->
      (try let _ = push_fn event in ()
       with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Sub.error "push_event failed: %s" (Printexc.to_string exn))
  | None ->
      if Atomic.compare_and_set unwired_warned false true then
        Log.Sub.info
          "push_event_to_sessions: registry not wired \
           (further calls silenced until set_session_push_fn runs)"
