(** The ego lite task space a browser Add-on worker serves as one live
    connection (RFC-browser-live-ego). The worker owns no browser process:
    each command runs [ego-browser nodejs] once, and the task space is what
    lasts. *)

(** The worker's arguments that carry [configuration]. Nothing in an ego
    connection needs cleanup after the worker, so it rides the command line
    instead of the cleanup descriptor. *)
val arguments : Browser_configuration.live_ego -> string list

(** Runs [command] with [arguments], writes [stdin] to it and answers
    everything it wrote on stdout and stderr together. A run that outlives
    [timeout_s] or writes more than {!Browser_ego_peer.output_limit_bytes}
    is stopped with its process group. *)
val run_command : env:Eio_unix.Stdenv.base -> timeout_s:float -> stdin:string -> command:string ->
  string list -> (string, Browser_ego_peer.run_failure) result

(** Runs one script as [command nodejs] and answers within the window the
    peer gives, stop included. A window no longer than the stop is refused
    before the run starts. *)
val runner : env:Eio_unix.Stdenv.base -> command:string -> Browser_ego_peer.runner

(** Read ego lite's version, open the task space, register one client and
    serve its commands until the owner retires; then end the task space. The
    caller's work starts once that client is attached. A configured ego that
    cannot start fails this worker's start, as the owned BiDi Firefox does.
    Screenshots pass through a private directory this run creates and
    removes. *)
val run : env:Eio_unix.Stdenv.base -> owner:Browser_addon_owner.t ->
  Browser_configuration.live_ego -> (unit -> unit) -> unit
