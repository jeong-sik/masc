(** Server_discord_builtin_bootstrap — start the in-process Discord
    gateway when {!Discord_builtin_config.builtin_enabled} is true
    (RFC-0203 Phase 2 dual-run boot wiring).

    Called once from [server_runtime_bootstrap.ml] after maintenance
    loops are wired. The gateway fiber is bound to the server-wide
    [Switch] so a graceful shutdown cancels it cleanly.

    During the dual-run window this only feeds the
    {!Discord_dual_run_stats} counters — events are not yet routed to
    keeper rooms (the Python sidecar still owns inbound delivery).
    Comparing the two paths' counters answers "is the OCaml gateway
    seeing the same event stream?" before we switch outbound. *)

val start_if_enabled
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> unit
(** No-op when the flag is off. When on but [DISCORD_BOT_TOKEN] is
    missing, logs [Log.Server.warn] and returns without starting —
    the server still boots so an operator can fix the env without a
    crash loop. *)
