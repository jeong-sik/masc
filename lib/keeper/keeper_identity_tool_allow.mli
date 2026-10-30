(** Keeper_identity_tool_allow — narrow an attached-service offering to the
    tools the Keeper's profile named (RFC-0403).

    A Keeper that attaches a service is handed that service's whole list.
    Measured 2026-09-02: one live keeper carried 122 tools and
    140 KB of schema, of which 84 tools and 94.4 KB had not been called in
    eight days of logs -- including four Confluence write tools, 21.3 KB,
    with zero calls in the whole tool-call record for a Keeper that reads.

    The existing axes do not reach this. [defer_loading] is per tool and
    global, and attached tools have no tool file to declare it in;
    [Keeper_identity_switch] is per provider, so switching Atlassian off to
    drop Confluence writes drops Jira reads with them.

    Static, because the two harnesses that tried both answers converged:
    OpenClaw closed per-turn dynamic loading as not planned (#23999) and
    shipped per-job static selection (#91820), which Hermes calls toolsets.
    Static also sidesteps what stops the official-client lanes from
    deferring at all -- those pin their tool set at process spawn, and a
    selection made before spawn is a set they can pin. *)

type outcome =
  { kept : Keeper_identity_tools.offered_tool list
        (** The offering, in its original order, minus what the profile did
            not name. Physically the input when the profile named nothing. *)
  ; unnamed : string list
        (** Names the profile asked for that the offering does not hold,
            sorted. A typo, or a provider that is switched off or not
            attached. Reported rather than swallowed: a silently dropped
            name removes a tool and says nothing, which is the failure this
            selection exists to make visible.

            Not an error on its own -- a profile may legitimately name a
            tool from a provider an operator has switched off, and that is
            already the state {!Keeper_identity_switch} reports. *)
  }

val apply
  :  allow:string list option
  -> Keeper_identity_tools.offered_tool list
  -> outcome
(** [apply ~allow offered] keeps the offered tools the profile named.

    [allow = None] is every offered tool: a profile that says nothing gets
    what it got before this module existed, byte for byte.

    [allow = Some []] is no attached tool at all. An explicit empty list and
    an absent one are opposite answers, which is why the profile carries an
    option rather than a list.

    Matching is on the tool's exact name. No prefix, no provider grouping:
    a rule that accepted [atlassian_*] would put the axis back on the
    provider, which is the granularity that already exists and does not
    answer this. *)
