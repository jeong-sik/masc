(** WebMCP consumer bridge (RFC-webmcp-keeper-consumption Lane B).

    Runs the embedded node bridge (canonical source:
    [dashboard/scripts/webmcp-bridge.mjs], embedded at build time) against a
    headed Chrome's CDP endpoint and returns the bridge's stdout verbatim.

    Every failure is a typed value. There is no retry, no fallback path, and
    no Chrome lifecycle management here: the operator owns the Chrome process
    (RFC §4), and a missing endpoint returns [Page_not_found] immediately. *)

type failure =
  | Bridge_unavailable of string
      (** node could not be spawned (missing binary, spawn error) or the
          embedded script could not be materialized. *)
  | Page_not_found of string
      (** The CDP endpoint answered but no page matched [page] (bridge exit
          2), or the endpoint itself was unreachable. *)
  | Surface_or_tool_missing of string
      (** The page has no [document.modelContext], or the requested tool is
          not registered (bridge exit 3). *)
  | Invalid_args of string  (** [args_json] is not a JSON object. *)
  | Bridge_failure of string
      (** Any other bridge outcome: timeout, non-zero exit outside the typed
          codes, signal. *)

val failure_message : failure -> string

type runner =
  timeout_sec:float ->
  string list ->
  (Unix.process_status * string * string, string) result
(** How the bridge process is executed: argv in, (status, stdout, stderr)
    out, [Error] when the process could not be spawned at all. The default
    wraps [Process_eio.run_argv_with_status_split]; tests inject a fake. *)

val list_tools :
  ?runner:runner ->
  ?cdp_port:int ->
  page:string ->
  unit ->
  (string, failure) result
(** JSON listing of the WebMCP tools the matched page registered. *)

val call_tool :
  ?runner:runner ->
  ?cdp_port:int ->
  page:string ->
  tool:string ->
  args_json:string ->
  unit ->
  (string, failure) result
(** Executes one registered tool with a JSON-object argument string and
    returns the bridge's JSON result ({v {found, result} v}) verbatim. *)

(** Exposed for tests. *)

val bridge_argv :
  script_path:string -> cdp_port:int -> page:string -> subcommand:string list -> string list

val classify_exit :
  Unix.process_status -> stdout:string -> stderr:string -> (string, failure) result
