(** A real native Runtime/MCP installation with a scripted browser adapter.
    No installed browser/profile is opened. The script observes the actual
    advertised-tool request and its answer passes through selected hooks. *)
type t
val detach : t -> unit
(** Wait for confirmed settlement of this fixture's workers. Idempotent. *)
val with_worker :
  ?clients:Browser_lane.client_info list ->
  ?downloads:(string * Yojson.Safe.t) list ->
  env:Eio_unix.Stdenv.base -> config:Masc.Workspace.config ->
  respond:(route:Browser_lane.route -> Browser_lane.verb -> Browser_lane.answer) ->
  (t -> 'a) -> 'a
(** One scripted worker per source the old single browser worker served: the
    owned automation and Stagehand sources, and the external hosts that list
    [clients], each of its own one-source package and answered by [respond].
    Owns attachment and confirmed detach of every one, and restores the prior
    PATH. Owns the Eio test context and full environment for that lifetime.
    Callers must not already hold [Eio_context.with_test_env]'s non-reentrant
    global test lock.
    The invoking test declares the native launcher executable as a Dune dep.
    Fixture responses describe the scripted adapter, not real-browser support.
    [downloads] maps a download grant id to the publication the scripted
    worker returns when the server claims that grant; commit and release are
    acknowledged. *)

(** One scripted worker of a package that serves [serves], reporting
    [clients] in its snapshot and, as registered, the automation and Stagehand
    sources it serves. Its package exports the browser command only when
    [exports]. *)
type worker = { serves : Browser_lane.Backend.t; clients : Browser_lane.client_info list; exports : bool }

(** A worker as attached: its instance, and the client ids of the native
    polls it answered. *)
type attached = { serves : Browser_lane.Backend.t; instance_id : string; polled : unit -> string list }

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
