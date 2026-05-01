open Base

(** Tool_catalog — Visibility and lifecycle metadata for MCP tools.

    Central registry for tool access control:
    - Visibility: Default (public) vs Hidden (internal-only)
    - Lifecycle: Active, Deprecated, Placeholder *)

(** {1 Types} *)

type visibility = Default | Hidden
type lifecycle = Active | Deprecated

type implementation_status =
  | Real
  | Adapter
  | Simulation
  | Placeholder

type effect_domain =
  | Read_only
  | Masc_coordination
  | Playground_write
  | Main_worktree_write

type tool_group =
  | Board
  | Knowledge
  | Tasks
  | Voice
  | Filesystem
  | Masc_board
  | Masc_keeper
  | Masc_plan
  | Masc_worktree
  | Masc_code
  | Masc_autoresearch
  | Masc_agent
  | Masc_core

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
  required_permission : Types.permission option;
  effect_domain : effect_domain option;
  requires_actor_binding : bool option;
}

(** {1 Configuration} *)

val default_metadata : metadata

val deprecated :
  ?canonical_name:string -> ?replacement:string ->
  ?allow_direct_call_when_hidden:bool ->
  ?implementation_status:implementation_status -> string -> metadata

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

val full_surface_override : unit -> bool
(** [true] when MASC_FULL_SURFACE=1 is set. *)

(** {1 Metadata lookup} *)

val metadata : string -> metadata
val implementation_status : string -> implementation_status
val effect_domain : string -> effect_domain option
val requires_actor_binding : string -> bool
val is_main_worktree_boundary_exempt : string -> bool option
val tool_group : string -> tool_group option
val canonical_tool_name : string -> string
val is_placeholder : string -> bool
val is_visible : ?include_hidden:bool -> ?include_deprecated:bool -> string -> bool
val allow_direct_call : string -> bool

(** {1 String conversions} *)

val visibility_to_string : visibility -> string
val lifecycle_to_string : lifecycle -> string
val implementation_status_to_string : implementation_status -> string
val effect_domain_to_string : effect_domain -> string
val tool_group_to_string : tool_group -> string

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

val deprecated_tool_entries : (string * metadata) list
(** Precomputed subset of [explicit_metadata] where lifecycle = Deprecated. *)

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
  | Keeper_internal
  | Keeper_denied
  | System_internal

val tools_for_surface : surface -> string list
(** Canonical tool name list for [surface]. *)

val is_on_surface : surface -> string -> bool
(** O(1) check: is [name] a member of [surface]? *)

val all_surfaces : surface list
(** All defined surface variants for iteration. *)

val surface_to_string : surface -> string
(** Machine-readable surface label. *)
