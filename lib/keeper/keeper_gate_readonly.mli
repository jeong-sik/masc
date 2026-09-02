(** Deterministic observation-only classification for Keeper tool_execute
    gate requests. See the implementation's header comment for the authority
    argument: the judge's stated authority is the concrete effect's safety,
    and for a shell-less observation-only argv inside the docker sandbox
    that question has a deterministic answer. *)

(** [readonly_sandbox_execute ~operation ~input] is [true] exactly when the
    gate request is a [tool_execute] whose argv is a closed-set
    observation-only command and whose declared sandbox is docker, or a
    [network_read] request whose capability is in the closed
    observation set ([web_search] — server-side, provider-bound, no
    caller-chosen address; [web_fetch] — caller-chosen URL whose reachable
    address set is refused by [Tool_misc_web_fetch] itself on every hop, so
    a judge reading the same URL string has nothing left to decide about
    the address).

    What this gives up, on purpose: the judge also saw the previous tool
    call, so a GET that carried bytes a keeper had just read in its query
    string was visible to it. This classification runs such a fetch
    unjudged. The decision rests on the measured record — 2026-09-01..02
    the judge approved 319 of 319 network reads and refused none — and on
    the cost, a median 173 s per fetch. Reverting it means removing
    [web_fetch] from [observation_network_capabilities]; nothing else
    depends on the choice.
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
