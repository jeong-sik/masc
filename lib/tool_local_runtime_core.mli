
(** Tool_local_runtime_core — types, helpers, process discovery,
    and OpenAI-compatible model fetching for local llama-server
    runtime probing.

    Its siblings ({!Tool_local_runtime},
    {!Tool_local_runtime_http}) do
    [include Tool_local_runtime_core], so this module's surface
    propagates as a re-export through every consumer.
    The concrete [llama_process] record carries observed process metadata
    without exposing a second cmdline-discovery path from this core module. *)

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
(** Single benchmark sample.  Currently unconsumed — the
    local-runtime bench/status loops that read it were removed. *)

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

(** {1 Model discovery} *)
