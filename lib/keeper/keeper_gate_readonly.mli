(** Deterministic observation-only classification for Keeper tool_execute
    gate requests. See the implementation's header comment for the authority
    argument: the judge's stated authority is the concrete effect's safety,
    and for a shell-less observation-only argv inside the docker sandbox
    that question has a deterministic answer. *)

(** [observation_only_request ~operation ~input] is [true] exactly when the
    gate request is a [tool_execute] whose argv is a closed-set
    observation-only command and whose declared sandbox is docker, or a
    [network_read] request whose capability is in the closed
    observation set ([web_search] — server-side, provider-bound, no
    caller-chosen address; [web_fetch] — caller-chosen URL whose literal
    destination [Tool_misc_web_fetch] checks itself on the initial URL and
    on every redirect hop: loopback, link-local, private, unspecified,
    localhost, non-canonical numeric spellings, userinfo, unparsed
    authority, and non-ASCII hosts are refused. It does not resolve DNS, so
    a public name that resolves to a private address is not caught there —
    and a judge reading the same URL string could not resolve it either).

    What this gives up, on purpose: the judge also saw the previous tool
    call, so a GET that carried bytes a keeper had just read in its query
    string was visible to it. This classification runs such a fetch
    unjudged. The record behind the decision — every network read the judge
    saw over 2026-09-01..02 was approved, at a median of minutes per fetch —
    is in docs/audits/keeper-fleet-waiting-audit-20260902.md §2. Reverting
    it means removing [web_fetch] from [observation_network_capabilities];
    nothing else depends on the choice.
    [true] means the request may be allowed without judgment or queueing;
    [false] means nothing — the request falls through to the configured
    gate mode. The execute input shape is
    [Keeper_tool_execute_runtime.execute_gate_input]; the network shape is
    the [network_read] gate request ([capability] at the top level). *)
val observation_only_request : operation:string -> input:Yojson.Safe.t -> bool

val observation_network_capabilities : string list

(** Exposed for tests: the argv classifier alone. *)
val classify_argv : string list -> bool

(** Exposed so tests can iterate the full closed sets. *)
val observation_commands : string list
val git_read_subcommands : string list
