(** Keeper_identity — Centralized keeper identity and trace ID management.

    Consolidates trace_id generation and session_id conventions.

    - [trace_id] is generated per keeper creation and per handoff rollover.
    - [session_id] is set equal to [trace_id] in [create_session].
    - Directory layout: [.masc/traces/<trace_id>/] per execution trace.

    @since 2.162.0 — #3721 keeper stabilization *)

(** Generate a new trace ID. Used at keeper creation and handoff rollover.
    Format: [trace-<epoch_ms>-<5hex>] *)
let generate_trace_id () : string =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFF in
  Printf.sprintf "trace-%d-%05x" ts hash
