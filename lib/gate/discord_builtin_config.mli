(** Discord_builtin_config — env-driven configuration for the
    in-process Discord gateway (RFC-0203 Phase 2 boot wiring).

    All inputs come from process env vars so dual-run cohort
    selection is a deploy-time toggle, not a code change. *)

(** {1 Feature flag}

    [MASC_DISCORD_BUILTIN] — default [false]. When [false] the
    server boot hook is a no-op (the Python sidecar keeps owning
    the connection). *)
val builtin_enabled : unit -> bool

(** {1 Trigger policy}

    [MASC_DISCORD_TRIGGER_POLICY] — closed sum, default
    [Mention_only]. Mirrors {!Discord_gateway_client.trigger_policy}
    so the parser can hand the value straight to [run]. *)
type policy_parse_error =
  | Empty
  | Unknown_value of string
  | User_only_missing_id  (** got [user_only:] with no id after colon *)

val pp_policy_parse_error : Format.formatter -> policy_parse_error -> unit

(** Parse a raw policy string (e.g. ["mention_only"], ["user_only:42"],
    ["all"]). Closed-sum errors so callers must handle every failure
    mode explicitly at the boundary. *)
val parse_policy
  :  string
  -> (Discord_gateway_client.trigger_policy, policy_parse_error) result

(** [trigger_policy ()] resolves the env var, defaulting to
    [Mention_only] when the var is unset, empty, or unparseable.
    Silent fallback to the safest behaviour (least-noisy fan-out)
    so an invalid override degrades to the safe default rather than
    refusing to boot. Use {!parse_policy} directly when you need to
    surface the parse error to the operator. *)
val trigger_policy : unit -> Discord_gateway_client.trigger_policy

(** {1 Token resolution}

    [DISCORD_BOT_TOKEN] — required when {!builtin_enabled} is true.
    [None] when unset/empty. *)
val bot_token : unit -> string option

(** {1 Intents}

    The full intent list mandated by RFC-0203 §Modules
    ([GUILDS | GUILD_MESSAGES | MESSAGE_CONTENT | GUILD_MESSAGE_REACTIONS |
    DIRECT_MESSAGES | DIRECT_MESSAGE_REACTIONS]). Threads ride
    [GUILD_MESSAGES]. *)
val intents : Discord_gateway_client.intent list
