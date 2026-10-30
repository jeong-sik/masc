
(** Tool_local_runtime_core — the types the local-runtime tools share
    (tool result, external-effect authorizer, context) and one string
    parse helper, [parse_int_opt].

    {!Tool_local_runtime_http} does [include Tool_local_runtime_core], so
    this module's surface is re-exported through it. *)

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

(** {1 Parse helpers} *)

val parse_int_opt : string -> int option
(** [parse_int_opt s] is {!int_of_string_opt} composed with
    {!String.trim} — convenience for cmdline / JSON-string-int
    coercion. *)
