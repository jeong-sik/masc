
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
  reason : string option;
  allow_direct_call_when_hidden : bool;
  readonly : bool option;
  mcp_context_required : bool option;
  idempotent : bool option;
  required_permission : Masc_domain.permission;
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

val default_metadata : required_permission:Masc_domain.permission -> metadata

(** {1 Public tool surface} *)

val is_public_mcp : string -> bool
(** O(1) membership check against the public surface. *)

(** {1 Metadata lookup} *)

val metadata : string -> metadata
val execution_policy_of_metadata :
  tool_name:string -> metadata -> (execution_policy, execution_policy_error) result
val execution_policy_error_to_string : execution_policy_error -> string
val implementation_status : string -> implementation_status
val is_visible : ?include_hidden:bool -> string -> bool
val allow_direct_call : string -> bool

(** {1 String conversions} *)

val visibility_to_string : visibility -> string
val lifecycle_to_string : lifecycle -> string
(** {1 JSON metadata} *)

val metadata_to_fields : string -> (string * Yojson.Safe.t) list
(** Full metadata as JSON key-value pairs. *)

(** Minimal metadata for public contract responses. *)

val register_runtime_metadata : string -> metadata -> (unit, string) result
(** Register runtime visibility/execution metadata while preserving the
    catalog-owned required permission. Unclassified tool names fail closed. *)

val registered_metadata : string -> metadata option

val known_names : unit -> string list
(** Every tool name this catalog carries metadata for, sorted and deduplicated.

    The schema lists elsewhere are not this set. A tool can have a catalog
    policy and keep its schema outside [Config]'s front door, and a contract
    test that walks the schema lists never reaches it — which is how the
    Hidden-with-direct-calls-denied branch went unexercised. *)
(** Explicit or [Tool_spec]-registered metadata, without surface-derived
    fallback metadata. *)

val explicit_metadata : (string * metadata) list
(** Explicitly configured tool metadata entries (for test verification). *)

module For_testing : sig
  val register_metadata : string -> metadata -> unit
  (** Install an arbitrary fixture entry, bypassing the production catalog
      ownership check. Production registration uses [register_runtime_metadata]. *)
end
