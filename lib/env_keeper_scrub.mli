(** Keeper subprocess env scrub / pass policy (RFC-0007 PR-1 / #9639 Cluster B).

    Long-lived host credentials (Anthropic API keys, AWS secrets, OIDC
    request tokens, OTel exporter bearer headers) MUST NOT cross the
    keeper subprocess boundary. They are consumed by the host process
    (MASC server) and are not needed inside the keeper container or shell
    subprocess.

    Job-scoped tokens ([GH_TOKEN], [GITHUB_TOKEN], [SSH_AUTH_SOCK], and
    other [GIT_*]) are explicitly passed through — they are expected
    consumers of gh/git operations and expire with the job.

    Design reference: [GHA_SUBPROCESS_SCRUB] in claude-code at
    [src/utils/subprocessEnv.ts:15-53]. Principle P2 of RFC-0007:
    "Scrub vs pass-through is decided by token scoping." *)

(** Env-var keys stripped before spawning a keeper subprocess. *)
val scrub : string list

(** Env-var keys explicitly allowed through, documented for callers. Does
    not participate in [filter_environment]'s positive list (everything
    not on [scrub] is already allowed); serves as an assertion against
    accidental future additions to [scrub]. *)
val pass : string list

(** [is_scrubbed key] returns [true] if the given env-var key is on the
    scrub list. Prefix-based entries (e.g. future [ANTHROPIC_*]) are not
    supported yet — exact match only. *)
val is_scrubbed : string -> bool

(** Return a copy of the given [Unix.environment]-shaped array with
    scrubbed keys removed. Entries that do not contain ['='] are kept
    as-is. *)
val filter_environment : string array -> string array
