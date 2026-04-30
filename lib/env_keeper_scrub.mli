(** Keeper subprocess env scrub / pass policy (RFC-0007 PR-1 / #9639 Cluster B).

    Long-lived host credentials (Anthropic API keys, AWS secrets, OIDC
    request tokens, OTel exporter bearer headers) MUST NOT cross the
    keeper subprocess boundary. They are consumed by the host process
    (MASC server) and are not needed inside the keeper container or shell
    subprocess.

    Keeper GitHub execution must use the selected MASC identity bundle,
    never the operator's ambient GitHub token/config or SSH agent.
    [GH_TOKEN], [GITHUB_TOKEN], [GH_CONFIG_DIR], and [SSH_AUTH_SOCK]
    are scrubbed at this boundary. Git config-location env such as
    [GIT_CONFIG_GLOBAL] is also scrubbed because it can inject host
    credential helpers; [GIT_*] non-secret behavior can still pass unless
    a key is explicitly listed in [scrub].

    Design reference: [GHA_SUBPROCESS_SCRUB] in claude-code at
    [src/utils/subprocessEnv.ts:15-53]. *)

val scrub : string list
(** Env-var keys stripped before spawning a keeper subprocess. *)

val pass : string list
(** Env-var keys explicitly allowed through, documented for callers. Does
    not participate in [filter_environment]'s positive list (everything
    not on [scrub] is already allowed); serves as an assertion against
    accidental future additions to [scrub]. *)

val is_scrubbed : string -> bool
(** [is_scrubbed key] returns [true] if the given env-var key is on the
    scrub list. Prefix-based entries (e.g. future [ANTHROPIC_*]) are not
    supported yet — exact match only. *)

val filter_environment : string array -> string array
(** Return a copy of the given [Unix.environment]-shaped array with
    scrubbed keys removed. Entries that do not contain ['='] are kept
    as-is. *)
