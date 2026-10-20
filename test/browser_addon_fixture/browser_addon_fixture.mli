(** A real native Runtime/MCP installation with a scripted browser adapter.
    No installed browser/profile is opened. The script observes the actual
    advertised-tool request and its answer passes through selected hooks. *)
type t
val detach : t -> unit
(** Wait for confirmed settlement of this fixture's exact worker. Idempotent. *)
val with_worker :
  ?clients:Browser_lane.client_info list ->
  env:Eio_unix.Stdenv.base -> config:Masc.Workspace.config ->
  respond:(route:Browser_lane.route -> Browser_lane.verb -> Browser_lane.answer) ->
  (t -> 'a) -> 'a
(** Owns attachment and confirmed worker detach, and restores the prior PATH.
    The invoking test declares the native launcher executable as a Dune dep.
    Fixture responses describe the scripted adapter, not real-browser support. *)
