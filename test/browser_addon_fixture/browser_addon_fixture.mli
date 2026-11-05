(** A real native Runtime/MCP installation with a scripted browser adapter.
    No installed browser/profile is opened. The script observes the actual
    advertised-tool request and its answer passes through selected hooks. *)
type t
val detach : t -> unit
(** Wait for confirmed settlement of this fixture's workers. Idempotent.
    Successful native Detach is authoritative even when a never-created
    worker leaves no retained Inspect record. *)
val with_worker :
  ?clients:Browser_lane.client_info list ->
  ?downloads:(string * Yojson.Safe.t) list ->
  env:Eio_unix.Stdenv.base -> config:Masc.Workspace.config ->
  respond:(route:Browser_lane.route -> Browser_lane.verb -> Browser_lane.answer) ->
  (t -> 'a) -> 'a
(** One scripted worker per source the old single browser worker served: the
    owned automation source and the external hosts that list
    [clients], each of its own one-source package and answered by [respond].
    Owns attachment and confirmed detach of every one, and restores the prior
    PATH and Runtime snapshot. Owns the Eio test context, an inert browser
    configuration and full environment for that lifetime; scripted workers
    never invoke the configured browser executables.
    Callers must not already hold [Eio_context.with_test_env]'s non-reentrant
    global test lock.
    The invoking test declares the native launcher executable as a Dune dep.
    Fixture responses describe the scripted adapter, not real-browser support.
    [downloads] maps a download grant id to the publication the scripted
    worker returns when the server claims that grant; commit and release are
    acknowledged. *)

(** One scripted worker of a package that serves [serves], reporting
    [clients] in its snapshot and, as registered, the automation source it
    serves. Its package exports the browser command only when
    [exports]. *)
type worker = { serves : Browser_lane.Backend.t; clients : Browser_lane.client_info list; exports : bool }

type snapshot_state = Snapshot_clients of Browser_lane.client_info list | Snapshot_unavailable
  | Snapshot_ego_refused of { space : string; ids : int list }
(** [Snapshot_unavailable] returns an incorrect reply type without stopping
    the serving worker, so its controller identity is unknown to the host. *)

(** A worker as attached: its exact instance, answered polls, and every typed
    command received before client admission. Snapshot controls do not issue
    browser commands. *)
type attached = {
  serves : Browser_lane.Backend.t;
  instance_id : string;
  polled : unit -> string list;
  commands : unit -> (Browser_lane.route * Browser_lane.verb) list;
  set_snapshot : snapshot_state -> unit;
}

val with_workers :
  ?received:(serves:Browser_lane.Backend.t -> route:Browser_lane.route -> unit) ->
  env:Eio_unix.Stdenv.base -> config:Masc.Workspace.config -> workers:worker list ->
  respond:(serves:Browser_lane.Backend.t -> route:Browser_lane.route -> Browser_lane.verb ->
    Browser_lane.answer) ->
  (attached list -> 'a) -> 'a
(** {!with_worker} for several workers at once, each of its own package.
    [received] is told of every command a worker receives, before the worker
    checks that it lists the client; [respond] answers only those whose
    client it lists. Every worker that attached is detached and settled when
    [run] returns or a later attach fails. Readiness waits only while startup
    is pending; an observed failed or stopping worker fails the fixture before
    invoking [run], retaining its native failure detail. *)
