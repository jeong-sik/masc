(** Tool_catalog — Visibility, lifecycle, and tier metadata for MCP tools.

    Central registry for tool access control:
    - Visibility: Default (public) vs Hidden (internal-only)
    - Lifecycle: Active, Deprecated, Placeholder
    - Tier: Essential (~20) < Standard (~50) < Full (all) *)

(** {1 Types} *)

type visibility = Default | Hidden
type lifecycle = Active | Deprecated

type implementation_status =
  | Real
  | Adapter
  | Simulation
  | Placeholder

type tier = Essential | Standard | Full

type metadata = {
  visibility : visibility;
  lifecycle : lifecycle;
  implementation_status : implementation_status;
  canonical_name : string option;
  replacement : string option;
  reason : string option;
  allow_direct_call_when_hidden : bool;
  readonly : bool option;
  destructive : bool option;
  idempotent : bool option;
}

(** {1 Configuration} *)

val default_metadata : metadata

val deprecated :
  ?canonical_name:string -> ?replacement:string ->
  ?allow_direct_call_when_hidden:bool ->
  ?implementation_status:implementation_status -> string -> metadata

val deprecated_default :
  ?canonical_name:string -> ?replacement:string ->
  ?implementation_status:implementation_status -> string -> metadata

val hidden_active :
  ?canonical_name:string -> ?replacement:string ->
  ?allow_direct_call_when_hidden:bool ->
  ?implementation_status:implementation_status -> string -> metadata

val placeholder_tools_enabled : unit -> bool

(** {1 Public tool surface} *)

val public_mcp_tools : string list
(** The curated list of tools exposed via tools/list (SSOT). *)

val is_public_mcp : string -> bool
(** O(1) membership check against the public surface. *)

val full_surface_override : unit -> bool
(** [true] when MASC_FULL_SURFACE=1 is set. *)

(** {1 Metadata lookup} *)

val metadata : string -> metadata
val implementation_status : string -> implementation_status
val is_placeholder : string -> bool
val is_visible : ?include_hidden:bool -> ?include_deprecated:bool -> string -> bool
val allow_direct_call : string -> bool

(** {1 String conversions} *)

val visibility_to_string : visibility -> string
val lifecycle_to_string : lifecycle -> string
val implementation_status_to_string : implementation_status -> string
val tier_to_string : tier -> string
val tier_of_string : string -> tier option

(** {1 Tier system} *)

val tool_tier : string -> tier
val is_in_tier : tier -> string -> bool
val tier_tool_count : tier -> int

val essential_tools : string list
val standard_tools : string list

(** {1 JSON metadata} *)

val metadata_to_fields : string -> (string * Yojson.Safe.t) list
(** Full metadata as JSON key-value pairs. *)

val public_contract_fields : string -> (string * Yojson.Safe.t) list
(** Minimal metadata for public contract responses. *)

val explicit_metadata : (string * metadata) list
(** Explicitly configured tool metadata entries (for test verification). *)

val deprecated_tool_entries : (string * metadata) list
(** Precomputed subset of [explicit_metadata] where lifecycle = Deprecated. *)

val implementation_allows_public_visibility : implementation_status -> bool
(** [true] when an implementation status permits public surface listing. *)

(** {1 Tool Surface System}

    Canonical surface membership SSOT. Use [tools_for_surface] to retrieve
    the tool name list for a given surface, and [is_on_surface] for O(1)
    membership checks. *)

type surface =
  | Public_mcp
  | Spawned_agent
  | Local_worker
  | Session_min
  | Admin
  | Keeper_denied
  | Mdal_auditable

val tools_for_surface : surface -> string list
(** Canonical tool name list for [surface]. *)

val is_on_surface : surface -> string -> bool
(** O(1) check: is [name] a member of [surface]? *)

val all_surfaces : surface list
(** All defined surface variants for iteration. *)

val surface_to_string : surface -> string
(** Machine-readable surface label. *)
