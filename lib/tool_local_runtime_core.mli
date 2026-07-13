
(** Tool_local_runtime_core — types, helpers, process discovery,
    and OpenAI-compatible model fetching for local llama-server
    runtime probing.

    Three siblings ({!Tool_local_runtime},
    {!Tool_local_runtime_http},
    {!Tool_local_runtime_status}) all do
    [include Tool_local_runtime_core], so this module's surface
    propagates as a re-export through every consumer.  The
    cmdline-flag-parsing helpers ([parse_pid_and_command],
    [find_flag_value], [has_flag], [server_port_of_url]) stay
    private — they are stable but exposing them would invite
    duplicate-discovery paths that drift from
    {!discover_processes}'s field-by-field cmdline parser. *)

(** {1 Types} *)

type tool_result = Tool_result.result
(** Typed local-runtime tool result. *)

type external_effect_authorizer =
  operation:string ->
  input:Yojson.Safe.t ->
  continue:(unit -> tool_result) ->
  tool_result
(** Optional caller-owned boundary around external effects. The local-runtime
    leaf selects the effect from its typed handler; the callback receives only
    the exact operation and complete input, without learning Gate policy. *)

type context = {
  config : Workspace.config;
  agent_name : string;
  authorize_external_effect : external_effect_authorizer option;
}

type llama_process = {
  pid : int option;
  command : string;
  port : int option;
  host : string option;
  alias : string option;
  model_path : string option;
  ctx_size : int option;
  batch_size : int option;
  ubatch_size : int option;
  slots_enabled : bool;
}
(** Discovered llama-server process.  Concrete record because
    operator dashboards render every field (pid + cmdline diff
    against the runtime config). *)

type bench_sample = {
  success : bool;
  latency_ms : int;
  error : string option;
}
(** Single benchmark sample.  Used by {!Tool_local_runtime_status}
    bench loops; exposed here so all four siblings see the same
    type via include. *)

(** Aliases over {!Json_util.*_opt_to_json} re-exported for the
    sibling include runtime. *)

(** {1 Parse helpers} *)

val parse_int_opt : string -> int option
(** [parse_int_opt s] is {!int_of_string_opt} composed with
    {!String.trim} — convenience for cmdline / JSON-string-int
    coercion. *)

(** Alias over {!Json_util.dedupe_keep_order}. *)

val split_ws : string -> string list
(** [split_ws text] returns argv-like literal words using the shared
    bash-subset word parser, preserving quoted values.  Used to tokenise
    cmdlines into argv-like lists for process discovery. *)

(** Alias over {!String_util.contains_substring} — case-
    sensitive. *)

(** {1 Process introspection} *)

val process_to_yojson : llama_process -> Yojson.Safe.t
(** Renders the 10-field JSON object.  Field order matches the
    record declaration; dashboards render in this order. *)

val process_matches_runtime_ports :
  int list -> llama_process -> bool
(** [process_matches_runtime_ports ports process] returns [true]
    iff [process.port] is in [ports].  Used to filter discovered
    processes to those bound to MASC-managed ports. *)

val discover_processes :
  unit -> (llama_process list, string) Result.t
(** [discover_processes ()] runs [ps -ax -o pid=,command=]
    through {!Masc_exec.Exec_gate.run_argv_with_status} and
    parses the output into typed records.

    {2 Filter}

    Two-stage filter on each line:
    1. Command must contain the substring [["llama-server"]].
    2. Some token must end with [["llama-server"]] (catches the
       binary path while excluding accidental
       "llama-server-something-else" matches).

    {2 Cmdline flag extraction (pinned)}

    | Flag | Field |
    |---|---|
    | [--port] | [port] (parsed int) |
    | [--host] | [host] |
    | [--alias] | [alias] |
    | [-m] | [model_path] |
    | [-c] | [ctx_size] (parsed int) |
    | [--batch-size] | [batch_size] |
    | [--ubatch-size] | [ubatch_size] |
    | [--slots] (presence) | [slots_enabled] |

    {2 Errors}

    Returns [Error "ps failed with exit code <N>"] /
    ["ps killed by signal <N>"] / ["ps stopped by signal <N>"]
    on subprocess failure.  5-second timeout (operator-tunable
    only by code change). *)

(** {1 Model discovery} *)

val fetch_models_at :
  string -> (string * string list, string) Result.t
(** [fetch_models_at base_url] runs
    [curl -sS --max-time 10 <base_url>/<openai_models_path>]
    and parses the OpenAI-compatible response.

    Returns [Ok (full_url, model_id_list)].  Errors:
    - JSON parse failure: ["invalid llama models response: <e>"]
    - subprocess failure: per [WEXITED]/[WSIGNALED]/[WSTOPPED]

    The URL trailing-suffix is
    {!Masc_network_defaults.openai_models_path} — pinning
    centrally so all siblings hit the same path. *)

val fetch_models : unit -> (string * string list, string) Result.t
(** Convenience wrapper over {!fetch_models_at} using
    {!Env_config.Local_runtime.server_url} as the base URL. *)
