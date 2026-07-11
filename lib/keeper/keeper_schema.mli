(** Keeper Schema — JSON Schema fragments for keeper authoring tools.

    Builds tool-input JSON schemas exposed by [tool_keeper_*] handlers and
    the dashboard authoring surface. *)

type sandbox_lifecycle_operation =
  | Sandbox_stop

type sandbox_lifecycle_policy = private
  { required_permission : Masc_domain.permission
  ; destructive : bool
  }

val all_sandbox_lifecycle_operations : sandbox_lifecycle_operation list
val sandbox_lifecycle_tool_name : sandbox_lifecycle_operation -> string
val sandbox_lifecycle_operation_of_tool_name : string -> sandbox_lifecycle_operation option
val sandbox_lifecycle_policy : sandbox_lifecycle_operation -> sandbox_lifecycle_policy

type sandbox_stop_target =
  | Stop_keeper of string
  | Stop_fleet

type sandbox_stop_request = private
  { target : sandbox_stop_target
  ; scope : Keeper_types_profile_sandbox.sandbox_stop_scope
  ; timeout_sec : float
  }

val parse_sandbox_stop_request :
  Yojson.Safe.t -> (sandbox_stop_request, string) result

type sandbox_status_request = private
  { keeper_name : string option
  ; verbose : bool
  ; include_preflight : bool
  ; timeout_sec : float
  }

val parse_sandbox_status_request :
  Yojson.Safe.t -> (sandbox_status_request, string) result

val sandbox_lifecycle_schemas : Masc_domain.tool_schema list
(** Canonical schemas for privileged sandbox lifecycle operations. *)


val tail_order_enum_strings : string list
(** Allowed values for log-tail ordering options. *)

val string_array_schema : Yojson.Safe.t
(** JSON schema fragment for a free-form [string list] field. *)

val tool_access_schema : string -> Yojson.Safe.t
(** Schema fragment for [meta.tool_access] (string-array tool candidate profile list);
    parameterised on the property description so create vs update tools
    can vary the surface without duplicating the body. *)

val keeper_schemas : Masc_domain.tool_schema list
(** Per-tool schemas for the keeper authoring surface. *)

val schemas : Masc_domain.tool_schema list
(** Alias for [keeper_schemas] used by the catalogue registry. *)
