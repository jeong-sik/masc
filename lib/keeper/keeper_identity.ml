(** Keeper_identity — Centralized keeper identity and trace ID management.

    Consolidates trace_id generation and session_id conventions.

    {b Current state (v2.162.0)}:
    - [trace_id] is generated per keeper creation and per handoff rollover.
    - [session_id] is currently set equal to [trace_id] in [create_session].
    - OAS checkpoint [session_id] therefore changes on every handoff,
      breaking checkpoint continuity across trace rollovers.

    {b Invariants to maintain}:
    - [trace_id] is ephemeral: it changes on handoff.
    - [session_id] should be stable across handoffs for a given keeper.
    - Directory layout: [.masc/traces/<trace_id>/] per execution trace.

    {b TODO(#3721)}: In a follow-up PR, decouple session_id from trace_id:
    - session_id := "keeper-" ^ keeper_name (stable per keeper lifetime)
    - trace_id := current ephemeral trace (for directory and metrics)
    - OAS checkpoint should use stable session_id for continuity.

    @since 2.162.0 — #3721 keeper stabilization *)

(** Generate a new trace ID. Used at keeper creation and handoff rollover.
    Format: [trace-<epoch_ms>-<5hex>] *)
let generate_trace_id () : string =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFF in
  Printf.sprintf "trace-%d-%05x" ts hash

(** Derive a stable session ID from keeper name.
    This is the target convention for OAS checkpoint continuity.
    Not yet used in create_session — see TODO above. *)
let stable_session_id (keeper_name : string) : string =
  Printf.sprintf "keeper-%s" keeper_name
