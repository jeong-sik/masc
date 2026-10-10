(** Starts the Keeper Firefox and its BiDi host when the server starts, for a
    workspace whose [runtime.toml] has [\[browser.live.bidi\]]
    (RFC-browser-keeper-firefox §3.2, §3.3).

    Only what is missing is started: no Firefox when its port already
    answers, no host when one holds the host lock. Both are started apart from
    the server ({!Posix_spawn_detached}), so a server that stops or restarts
    leaves them running. Firefox writes to [keeper-firefox.log] and the host to
    [bidi-host.log] under [.masc/browser-lane]. Nothing is started while
    [\[browser.live\] enabled = false]. What happened is logged; the work runs
    in its own fiber and never holds up the server start.

    A Firefox started here that is left with no host (its port did not
    open in time, or the host could not be started) is stopped by its
    process group; one that was running already is not touched. A host is
    started only once the workspace's host lock is free, waiting a few
    seconds for a host that wrote its ending and is still exiting.

    While the server runs, a Keeper's request for work only a BiDi
    connection serves, with none listed, starts what is missing the same
    way and waits for the connection ({!Browser_keeper_firefox_starter},
    §3.5). One start runs at a time; a request that comes while one runs is
    answered with it. [configuration] is read at the server start and again
    at each request. *)

val start :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  base_path:string ->
  configuration:(unit -> Browser_configuration.t option) ->
  unit

module For_testing : sig
  (** The same work, resolved once Firefox and the host were started, found,
      or not started, waiting [ready_timeout_s] for Firefox's port rather
      than {!Browser_keeper_firefox.firefox_ready_timeout_s}, and
      [ending_host_wait_s] for an ending host to give its lock up. *)
  val start :
    ?ending_host_wait_s:float ->
    ready_timeout_s:float ->
    sw:Eio.Switch.t ->
    env:Eio_unix.Stdenv.base ->
    base_path:string ->
    configuration:Browser_configuration.t option ->
    unit ->
    (unit, exn) result Eio.Promise.t

  (** What the server installs for a Keeper's requests, serving starts on
      [sw] and waiting [host_attach_wait_s] for the connection. [boot]: the
      server start's own start runs first, as {!start} runs it, and answers
      the requests that come meanwhile; without it only requests start. *)
  val serve :
    ?ending_host_wait_s:float ->
    ?boot:bool ->
    ready_timeout_s:float ->
    host_attach_wait_s:float ->
    sw:Eio.Switch.t ->
    env:Eio_unix.Stdenv.base ->
    base_path:string ->
    configuration:(unit -> Browser_configuration.t option) ->
    unit ->
    unit ->
    Browser_keeper_firefox_starter.outcome
end
