(** Read model for Goal x Task x Board x Reward coordination snapshots.

    The projection is advisory and read-only. It gathers facts from existing
    stores and feeds the pure {!Coordination_product} invariant checker. *)

type severity_counts =
  { info : int
  ; warn : int
  ; error : int
  }

val build : Coord.config -> Coordination_product.snapshot
(** Build a live coordination product snapshot from existing runtime stores. *)

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
