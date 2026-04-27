(** Provider × MCP-config-construct matrix audit (Leak 12).

    SSOT for "does provider P have an active auto-construct path
    that supplies an MCP config JSON to its CLI subprocess?"

    This is the matrix that PR-Mp1 (unified construct API) will
    eventually collapse.  Until then, this module is the single
    place a boot hook (or a developer auditing the system) can ask
    the question and get a structured answer per provider. *)

type construct_path =
  | Auto_construct_active of {
      env_flag : string;
      default_when_unset : bool;
      module_name : string;
    }
  | No_auto_construct_path of { reason : string }
  | Not_applicable_http_api

type result = {
  provider : string;
  construct : construct_path;
}

val lookup : string -> result
(** SSOT lookup.  Recognises the canonical provider names plus a
    handful of common short forms (e.g. [claude] for [claude_code]).
    Unknown providers map to [No_auto_construct_path] with a reason
    that points at this module — the goal is fail-loud rather than
    fail-silent for any new provider added to a cascade. *)

val auto_construct_active_by_default : result -> bool
(** True iff the auto-construct path is on at server boot without
    requiring operator env intervention.  HTTP API providers count
    as "true" because they have no MCP client and therefore need no
    construct path. *)

val format_log_line : result -> string
(** Grep-friendly tag:
    [[mcp_audit:active|no_construct_path|http_api]]. *)

val audit_providers : string list -> result list
(** Pure mapping over [lookup]; the typical input is a cascade's
    provider list extracted from cascade.toml. *)

val partition :
  result list -> result list * result list * result list
(** Bucket into [(active, no_construct_path, http_api)] in input
    order. *)
