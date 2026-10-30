(** The ego lite task space a browser Add-on worker serves as one live
    connection (RFC-browser-live-ego). The worker owns no browser process:
    one [ego-browser nodejs] process runs the connection's commands, one at
    a time, and the task space is what lasts. Owner IPC end/close/error
    terminates that SDK process, including pending async work, without
    finishing the task space or undoing dispatched browser effects. This
    requires a responsive Node event loop. *)

(** The worker's arguments that carry [configuration]. Ego owns the browser;
    the worker owns its SDK session through IPC lifetime. No separate browser
    process cleanup descriptor is used. *)
val arguments : Browser_configuration.live_ego -> string list

(** Runs [command] with [arguments], writes [stdin] to it and answers
    everything it wrote on stdout and stderr together. A run that outlives
    [timeout_s] or writes more than {!Browser_ego_peer.output_limit_bytes}
    is stopped with its process group. *)
val run_command : env:Eio_unix.Stdenv.base -> timeout_s:float -> stdin:string -> command:string ->
  string list -> (string, Browser_ego_peer.run_failure) result

(** The [command nodejs] process that runs a connection's scripts. It is
    started by the first command, under [sw], and connects back to a socket
    in [directory], which only this connection may write to. *)
type session
val session : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> command:string -> directory:string -> session

(** Runs one script in the session's process and answers within the window
    the peer gives, stop included. A script that does not answer in time,
    writes past {!Browser_ego_peer.output_limit_bytes} or is cancelled stops
    the process with its group, and the next script starts another. A window
    no longer than the stop is refused before anything runs. *)
val runner : session -> Browser_ego_peer.runner

(** Uses the same process without a cumulative command window. Native SDK
    waits retain their own timeouts; cancellation stops and reaps the process. *)
val native_runner : session -> string -> (string, Browser_ego_peer.run_failure) result

(** Closes the session's socket, so its process leaves its loop and exits,
    and stops what is left of it. *)
val end_session : session -> unit

(** Read ego lite's version, open the task space, register one client and
    serve its commands until the owner retires; then stop only the SDK session.
    Task completion requires explicit [finish_space]. Retained/uncertain Spaces
    preserve browser-backed files and report unconfirmed backend cleanup. The
    caller's work starts once that client is attached. A configured ego that
    cannot start fails this worker's start, as the owned BiDi Firefox does,
    except when the space is configured by name and a read-only listing
    confirms a user-owned space with that name. Then the space is untouched
    and Ego is published as unavailable.
    Screenshots pass through a private directory this run creates and
    removes. Downloads its agent pages start are saved under [downloads],
    the worker's download folder, and published through [owner]. *)
val run : env:Eio_unix.Stdenv.base -> owner:Browser_addon_owner.t -> downloads:string ->
  Browser_configuration.live_ego -> (unit -> unit) -> unit
