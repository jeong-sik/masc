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
    caller-chosen address; [web_fetch] deliberately stays with the judge).
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
