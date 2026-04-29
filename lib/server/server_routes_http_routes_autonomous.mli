(** Autonomous phase taxonomy HTTP surface.

    Cycle 27 / Tier D2. Operator-facing read-only view over the
    {!Autonomous.Autonomous_phase} static taxonomy.

    {1 Routes}

    {v
      GET /api/v1/autonomous/phases       — 8 phase symbols
      GET /api/v1/autonomous/transitions  — 19 valid transitions
    v}

    {1 Why a separate module}

    [Server_routes_http_routes_multimodal] (Tier D1) handles the
    keeper-side workspace; this module exposes the {b static}
    autonomous-phase metadata that drives the dashboard's phase
    diagram. The two are namespaced under different
    [/api/v1/...] prefixes and are file-disjoint.

    The dynamic per-keeper phase {b state} (live
    [autonomous_meta] from working_context) is reserved for a
    follow-up PR — this module only ships the static enumeration. *)

val phases_response : unit -> Yojson.Safe.t
(** [{ "count": 8, "phases": [{ "tag": "idle", "symbol": "idle" }, ...] }]
    listing every phase witness. *)

val transitions_response : unit -> Yojson.Safe.t
(** [{ "count": 19, "transitions": [{ "tag": "T_idle_to_perceiving",
       "symbol": "idle->perceiving" }, ...] }] listing every
    valid transition. *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
(** Register the two GET routes under [/api/v1/autonomous/]. *)
