(** Contract 2 — Unified Sandbox, microVM & Remote SSH Fleet API
    ([GET /api/v1/infra/sandboxes], [GET /api/v1/infra/sandboxes/:keeper],
    [POST /api/v1/infra/sandboxes/probe]).

    Serves non-blocking cached telemetry joining:
    - [apple_container] microVMs ([.sock] liveness, shim build-identity parity,
      volume & host storage health),
    - [remote_ssh] pooled hosts & per-Keeper sessions (ending
      [Remote_execution_unobserved]), and
    - 24h tool failure breakdown from [tool-metrics.sqlite3].

    HTTP handlers never run blocking subprocess or network probes inline: cold
    or stale reads return immediately from the fast in-memory/stat projection
    and trigger a single-flight background refresh fiber. *)

type probe_state =
  | Probe_fresh
  | Probe_warming
  | Probe_stale
  | Probe_error of string

val probe_state_to_string : probe_state -> string

type shim_parity =
  | Shim_matched of { build_identity : string }
  | Shim_mismatch of { shim : string; server : string option }
  | Shim_undeclared
  | Shim_unavailable of string

val check_shim_parity : base_path:string -> shim_parity
(** Inspect [<base_path>/.masc/microvm/shim/masc-exec-shim] and compare its
    embedded {!Source_identity} against {!Source_identity.current}. *)

type ssh_reachability =
  | Ssh_probe_pending
  | Ssh_reachable of { rtt_ms : float; measured_at : float }
  | Ssh_unreachable of { detail : string; measured_at : float }

val build_snapshot_json :
  ?now:float ->
  ?probe_state:probe_state ->
  ?apple_inventory:(Keeper_microvm_guest_inventory.t, string) result option ->
  ?ssh_reachability:(string * ssh_reachability) list ->
  ?tool_series:(Tool_metrics_series.t, string) result option ->
  base_path:string ->
  unit ->
  Yojson.Safe.t
(** Pure/non-blocking projection builder joining declared Keepers, microVM
    sockets & shim parity, volume GC report, configured SSH pools & in-memory
    lane reports, and optional pre-fetched Apple inventory / SSH RTT / 24h tool
    metrics. Never spawns subprocesses or network sockets. *)

val get_fleet_json :
  ?sw:Eio.Switch.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?now:float ->
  base_path:string ->
  unit ->
  Yojson.Safe.t
(** Non-blocking handler projection for [GET /api/v1/infra/sandboxes]. Returns
    the cached snapshot if fresh, or returns immediately and schedules a
    single-flight background refresh when [sw] and [clock] are provided. *)

val get_keeper_json :
  ?sw:Eio.Switch.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?now:float ->
  base_path:string ->
  keeper:string ->
  unit ->
  (Yojson.Safe.t, Httpun.Status.t * Yojson.Safe.t) result
(** Non-blocking deep sandbox telemetry for [GET /api/v1/infra/sandboxes/:keeper]. *)

val trigger_probe :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  base_path:string ->
  unit ->
  bool
(** Schedule an immediate non-blocking background refresh. Returns [true] if a
    new refresh fiber was forked or [false] if one is already in flight. *)

val clear_cache_for_testing : unit -> unit

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t ->
  Http_server_eio.Router.t
(** Register [/api/v1/infra/sandboxes], [/api/v1/infra/sandboxes/:keeper], and
    [POST /api/v1/infra/sandboxes/probe]. *)
