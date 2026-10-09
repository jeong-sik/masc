(** Starts the Keeper Firefox and its BiDi host when the server starts, for a
    workspace whose [runtime.toml] has [\[browser.live.bidi\]]
    (RFC-browser-keeper-firefox §3.2, §3.3).

    Only what is missing is started: no Firefox when its port already
    answers, no host when one holds the host lock. Both are started apart from
    the server ({!Posix_spawn_detached}), so a server that stops or restarts
    leaves them running. Firefox writes to [keeper-firefox.log] and the host to
    [bidi-host.log] under [.masc/browser-lane]. Nothing is started while
    [\[browser.live\] enabled = false]. What happened is logged; the work runs
    in its own fiber and never holds up the server start. *)

val start :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  base_path:string ->
  configuration:Browser_configuration.t option ->
  unit

module For_testing : sig
  (** The same work, resolved once Firefox and the host were started, found,
      or not started, waiting [ready_timeout_s] for Firefox's port rather
      than {!Browser_keeper_firefox.firefox_ready_timeout_s}. *)
  val start :
    ready_timeout_s:float ->
    sw:Eio.Switch.t ->
    env:Eio_unix.Stdenv.base ->
    base_path:string ->
    configuration:Browser_configuration.t option ->
    (unit, exn) result Eio.Promise.t
end
