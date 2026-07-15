
(** Tool_catalog — Visibility metadata for MCP tools.

    Central registry for tool access control:
    - Visibility: Default (public) vs Hidden (internal-only)
    - Implementation status: Real, Adapter, Simulation, Placeholder *)

(** {1 Types} *)

type visibility = Default | Hidden
type lifecycle = Active

type implementation_status =
  | Real
  | Adapter
  | Simulation
  | Placeholder

type metadata = {
  visibility : visibility;
  lifecycle : lifecycle;
  implementation_status : implementation_status;
  required_permission : Masc_domain.permission;
  canonical_name : string option;
  replacement : string option;
  reason : string option;
  allow_direct_call_when_hidden : bool;
  readonly : bool option;
  mcp_context_required : bool option;
  idempotent : bool option;
}

type execution_policy_axis =
  | Read_only_axis
  | Idempotent_axis
  | Mcp_context_required_axis

type execution_policy = {
  is_read_only : bool;
  is_idempotent : bool;
  mcp_context_required : bool;
}

type execution_policy_error =
  | Missing_execution_policy of
      { tool_name : string
      ; missing_axes : execution_policy_axis list
      }

(** {1 Configuration} *)

val default_metadata : metadata

val hidden_active :
  ?canonical_name:string -> ?replacement:string ->
  ?allow_direct_call_when_hidden:bool ->
  ?implementation_status:implementation_status -> string -> metadata

val placeholder_tools_enabled : unit -> bool

(** {1 Public tool surface} *)

val public_mcp_tools : string list
(** Alias for [Tool_catalog_surfaces.public_mcp_surface_tools].
    Prefer the surfaces module directly for new code. *)

val is_public_mcp : string -> bool
(** O(1) membership check against the public surface. *)

(** {1 Metadata lookup} *)

val metadata : string -> metadata
val required_permission : string -> Masc_domain.permission
(** Typed authorization requirement for a tool. Unknown tools inherit the
    catalog default, [CanBroadcast]; callers must still reject unknown tool
    names before consulting this value. *)
val execution_policy_of_metadata :
  tool_name:string -> metadata -> (execution_policy, execution_policy_error) result
val execution_policy_error_to_string : execution_policy_error -> string
val implementation_status : string -> implementation_status
val canonical_tool_name : string -> string
val is_placeholder : string -> bool
val is_visible : ?include_hidden:bool -> string -> bool
val allow_direct_call : string -> bool

(** {1 String conversions} *)

val visibility_to_string : visibility -> string
val lifecycle_to_string : lifecycle -> string
val implementation_status_to_string : implementation_status -> string

(** {1 JSON metadata} *)

val metadata_to_fields : string -> (string * Yojson.Safe.t) list
(** Full metadata as JSON key-value pairs. *)

val public_contract_fields : string -> (string * Yojson.Safe.t) list
(** Minimal metadata for public contract responses. *)

val register_metadata : string -> metadata -> unit
(** Register runtime metadata for a tool. Called by [Tool_spec.register].
    Overwrites any previous entry for the same name. *)

val registered_metadata : string -> metadata option
(** Explicit or [Tool_spec]-registered metadata, without surface-derived
    fallback metadata. *)

val explicit_metadata : (string * metadata) list
(** Explicitly configured tool metadata entries (for test verification). *)
