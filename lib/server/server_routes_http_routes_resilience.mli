(** Resilience taxonomy HTTP surface.

    Cycle 27 / Tier D3. Operator-facing read-only view over the
    {!Resilience.Degradation} levels and the
    {!Resilience.Recovery} strategy classes.

    {1 Routes}

    {v
      GET /api/v1/resilience/levels      — 4 degradation levels
      GET /api/v1/resilience/strategies  — 4 strategy classes
    v}

    {1 Why a separate module}

    The static taxonomy is what the dashboard renders as the
    "resilience legend" panel: which level represents what, which
    strategy classes the keeper might apply. Per-keeper dynamic
    [resilience_meta] (live classification timeline) is reserved
    for a follow-up PR. *)

val levels_response : unit -> Yojson.Safe.t
(** [{ "count": 4, "levels": [{ "tag": "L1", "symbol": "L1",
       "rank": 1, "description": "..." }, ...] }] listing every
    degradation level with its rank ordering and a short
    operator-facing description. *)

val strategies_response : unit -> Yojson.Safe.t
(** [{ "count": 4, "strategies": [{ "tag": "Retry",
       "description": "..." }, ...] }] listing every strategy
    class produced by {!Resilience.Recovery.default_strategy}. *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
(** Register the two GET routes under [/api/v1/resilience/]. *)
