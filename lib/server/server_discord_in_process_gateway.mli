(** Server_discord_in_process_gateway — OCaml gateway that replaces
    the deleted [sidecars/discord-bot/] Python connector.

    Spawned once during server bootstrap. Forks a long-running fiber
    on the server-wide [Eio.Switch.t] that:

    1. Opens a WSS connection to Discord Gateway v10
       ({!Discord_gateway_client.run}).
    2. For each accepted [Message_create] event, looks up the
       channel→keeper binding
       ({!Channel_gate_discord_state.keeper_for_channel_result}), runs the
       keeper turn through {!Channel_gate.handle_inbound_streaming},
       projects redacted text snapshots by posting/editing one Discord
       reply, and falls back to
       {!Channel_gate_discord_state.send_message} when streaming never
       starts or fails.

    Always-on by design: there is no [MASC_DISCORD_BUILTIN]-style
    toggle. The legacy Python sidecar is gone — there is no
    fallback path to switch back to. If
    [DISCORD_BOT_TOKEN] is unset the gateway logs a warning and
    skips startup; the server still boots normally.

    See: docs/rfc/RFC-0203-discord-builtin-gateway.md §Phase 3. *)

val default_trigger_policy : Discord_gateway_client.trigger_policy
(** Policy used when none is configured (empty/unset): the quiet,
    mention-triggered baseline ([Mention_or_thread]). *)

(** Typed trigger-policy loading, mirroring the Slack sibling. A missing
    runtime.toml or missing key is "unset"; unreadable/malformed
    TOML, a wrong field type, or a value the strict grammar rejects is an
    explicit load error — the gateway does not start on one (fail-closed,
    masc#25123). *)
type trigger_policy_toml_load =
  | Runtime_toml_missing
  | Trigger_policy_missing
  | Trigger_policy_loaded of Discord_gateway_client.trigger_policy

type trigger_policy_load_error =
  | Runtime_toml_unreadable of { path : string; detail : string }
  | Runtime_toml_invalid of { path : string; detail : string }
  | Trigger_policy_invalid of { path : string; detail : string }
  | Trigger_policy_env_invalid of { detail : string }

val trigger_policy_load_error_to_string : trigger_policy_load_error -> string

val load_trigger_policy_from_toml :
  path:string -> (trigger_policy_toml_load, trigger_policy_load_error) result
(** Exposed for unit testing the config boundary. *)

val resolved_trigger_policy :
  unit -> (Discord_gateway_client.trigger_policy, trigger_policy_load_error) result
(** Env > TOML > default. [MASC_DISCORD_TRIGGER_POLICY] wins when set and
    valid; an invalid env value is a load error (never a silent default);
    otherwise the [discord.trigger_policy] runtime.toml key applies, and a
    missing file/key yields {!default_trigger_policy}. *)

module For_testing : sig
  val submit_triggered_event :
    ?deliver:(unit -> unit) ->
    Connector_ingress_lane.t ->
    dispatch_for_delivery:
      (Gate_keeper_backend.connector_delivery -> Channel_gate.dispatch_fn) ->
    base_dir:string ->
    Discord_gateway_client.gateway_event ->
    unit
end

val start :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  state:Mcp_server.server_state ->
  unit
(** Fork the gateway fiber. Returns immediately. Warnings and the
    eventual gateway crash (if any) are emitted via [Log.Server].
    Cancellation propagates through [~sw]. *)
