(** Read model for Goal x Task x Board x Reward coordination snapshots.

    The projection is advisory and read-only. It gathers facts from existing
    stores and feeds the pure {!Coordination_product} invariant checker. *)

type severity_counts =
  { info : int
  ; warn : int
  ; error : int
  }

type observed_state =
  { goals : Goal_store.goal list
  ; tasks : Masc_domain.task list
  ; posts : Board.post list
  ; transactions : Agent_economy.transaction list
  ; telemetry_events : Telemetry_eio.event_record list
  ; persist_errors : int
  ; economy_enabled : bool
  }
(** Captured non-deterministic inputs for the coordination projection.

    Store reads, clock reads, feature flags, and global counters belong before
    this boundary. Consumers can pass a fixed value to {!project} for
    repeatable tests and diagnostics. *)

val capture : Coord.config -> observed_state
(** Capture live runtime inputs from the existing stores. *)

val project : observed_state -> Coordination_product.snapshot
(** Deterministically project captured inputs into the pure product FSM view. *)

val build : Coord.config -> Coordination_product.snapshot
(** Build a live coordination product snapshot from existing runtime stores.

    Equivalent to [capture config |> project]. *)

val severity_counts : Coordination_product.snapshot -> severity_counts
(** Count snapshot violations by severity. *)

val to_yojson : Coordination_product.snapshot -> Yojson.Safe.t
(** Serialize a snapshot using the stable dashboard/MCP JSON shape. *)

val build_yojson : Coord.config -> Yojson.Safe.t
(** Build and serialize a snapshot. *)

val safe_build_yojson : Coord.config -> Yojson.Safe.t
(** Build and serialize a snapshot without raising.

    On projection failure the result keeps the normal snapshot shape with empty
    products/violations and a [projection_error] field. *)

val safe_build_tool_yojson : Coord.config -> Yojson.Safe.t
(** Bounded variant for MCP/tool calls.

    Keeps the advisory summary shape but caps expensive evidence reads and
    serialized products so live diagnostics cannot monopolize the tool call
    worker on large runtime state. *)
