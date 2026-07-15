(** Agent-facing tool descriptor spine.

    This module owns the schema-allowed capability names and their projection to
    internal keeper handlers.  Domain modules such as shell, connector, and
    filesystem remain implementation details behind the descriptor-selected
    executor/backend/sandbox route. *)

type executor =
  | Shell_ir
  | Filesystem
  | In_process

type backend =
  | Ocaml_runtime
  | Host_process
  | Sandbox_process

type sandbox =
  | No_sandbox
  | Host_allowed_paths
  | Turn_sandbox
  | Docker_profile
  | Backend_selected

(** One explicit Keeper-model exposure choice per descriptor. Compatibility
    aliases remain routable at transport boundaries but never become a second
    model-facing name. [Transport_alias] identifies a descriptor whose exact
    capability is already projected by another descriptor; it is not a
    subjective visibility policy. *)
type keeper_model_projection =
  | Preferred_public_name
  | Internal_name
  | Transport_alias of { projected_by : string }

(** Descriptor-owned model description enrichment. The dynamic task-state
    context is explicit metadata rather than an internal-name comparison in
    the OAS bundle assembler. *)
type model_description_projection =
  | Static_description
  | Current_task_state

(** Typed display group for Keeper capability discovery. *)
type keeper_tool_group =
  | Execute_group
  | Search_files_group
  | Filesystem_group
  | Board_group
  | Voice_group
  | Workspace_group
  | Surface_group
  | Memory_group
  | Meta_group
  | Core_group

(** Provenance of the descriptor input schema. A missing canonical cluster
    schema excludes that descriptor from model projection and is reported by
    the schema injection boundary. *)
type input_schema_source =
  | Descriptor_owned
  | Canonical_registry
  | Missing_canonical_registry

type readonly_of_input = Yojson.Safe.t -> bool option

type runtime_handler =
  | Tool_execute
  | Tool_search_files
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_time_now
  | Tool_tools_list
  | Tool_tool_search
  | Tool_context_status
  | Tool_memory_search
  | Tool_memory_write
  | Tool_library_search
  | Tool_library_read
  | Tool_surface_read
  | Tool_surface_post
  | Tool_person_note_set
  | Tool_ide_annotate
  | Tool_voice_dispatch
  | Tool_task_dispatch
  | Board_tool_dispatch
  | Tool_masc_board_dispatch
  | Tool_masc_task_dispatch
  | Tool_masc_plan_dispatch
  | Tool_masc_run_dispatch
  | Tool_masc_agent_dispatch
  | Tool_masc_workspace_dispatch
  | Tool_masc_misc_dispatch
  | Tool_web_search
  | Tool_web_fetch
  | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch
  | Tool_masc_schedule_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_fusion_dispatch
  | Tool_masc_fusion_status
  | Tool_masc_library_dispatch
  | Tool_masc_local_runtime_dispatch
  | Tool_analyze_image

type policy =
  { readonly_of_input : readonly_of_input
  ; readonly_hint : bool option
  ; retryable : bool
  ; cwd_scope : string option
  ; inline_safe : bool
  ; polling_read : bool
  }

type t =
  { id : string
  ; keeper_model_projection : keeper_model_projection
  ; model_description_projection : model_description_projection
  ; keeper_tool_group : keeper_tool_group
  ; input_schema_source : input_schema_source
  ; public_name : string
  ; public_aliases : string list
  ; internal_name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; policy : policy
  ; executor : executor
  ; backend : backend
  ; sandbox : sandbox
  ; runtime_handler : runtime_handler
  ; translate : Yojson.Safe.t -> Yojson.Safe.t
  ; validate_translated_input : bool
  (** Whether alias dispatch should validate [translate input] against the
      internal handler schema. Defaults to true; false is reserved for
      descriptor-owned public aliases whose runtime schema still differs from
      the public schema. *)
  ; receipt_labels : (string * string) list
  (** Evaluation-only semantic tags emitted in route evidence. These tags
      support replay/harness scoring and are not runtime selection policy. *)
  ; eval_tags : string list
  ; examples : Yojson.Safe.t list
  (** Descriptor-owned discovery examples. Empty means the discovery projection
      omits the [examples] field. *)
  }

val executor_to_string : executor -> string
val backend_to_string : backend -> string
val sandbox_to_string : sandbox -> string
val keeper_model_projection_to_string : keeper_model_projection -> string
val model_description_projection_to_string : model_description_projection -> string
val keeper_tool_group_to_string : keeper_tool_group -> string
val input_schema_source_to_string : input_schema_source -> string
val runtime_handler_to_string : runtime_handler -> string

(** [public_descriptors] is the LLM-native public surface (RFC-0064 hard-cut).
    Each descriptor has one preferred [public_name] and may expose secondary
    [public_aliases] that reuse the same schema/translation/runtime. *)
val public_descriptors : t list

(** [internal_descriptors] is the descriptor-backed workspace surface
    (RFC-0179). Starts empty; each cluster migration PR adds entries that map
    [keeper_*] / [masc_*] workspace tools to a typed handler. Not part of
    the LLM-native public-name contract. *)
val internal_descriptors : t list

(** [all_descriptors ()] is [public_descriptors @ internal_descriptors]. The
    runtime dispatcher walks this list to resolve [internal_name] for any
    descriptor-backed tool, regardless of LLM-native vs workspace origin. *)
val all_descriptors : unit -> t list

(** Objective schema-shape errors that prevent model projection. Empty means
    the descriptor has a resolved object schema whose structural fields are
    well-formed. *)
val model_schema_errors : t -> string list

(** Descriptors with one explicit model-facing projection and a resolved input
    schema. Only exact transport aliases and missing/structurally invalid schemas
    are excluded. *)
val model_visible_descriptors : unit -> t list

(** The sole active Keeper model name. Empty only for an exact
    [Transport_alias] or a descriptor without a resolved schema. *)
val keeper_model_names : t -> string list

(** Names admitted by the Keeper execution/candidate boundary. A preferred
    public descriptor retains compatibility aliases and its internal handler
    route for transport/runtime dispatch. Only [keeper_model_names] controls
    the model schema, so these aliases cannot become duplicate model tools. *)
val keeper_candidate_names : t -> string list

(** Every name owned by a descriptor, including transport-alias names. This is
    for name-integrity checks, never Keeper execution admission. *)
val registered_names : t -> string list

val public_names_of_descriptor : t -> string list
val public_names : unit -> string list
val internal_names : t -> string list
val find_public : string -> t option
val public_name_for_internal : string -> string option
val public_descriptors_for_internal : string -> t list

(** [descriptors_for_internal name] walks [all_descriptors ()]. Use this from
    the runtime dispatcher to support descriptor-backed workspace tools
    alongside the LLM-native descriptors. *)
val descriptors_for_internal : string -> t list

val readonly_static_hint : t -> bool option
val readonly_for_input : t -> input:Yojson.Safe.t -> bool option

(** Descriptor-owned read-only projection. The returned names are internal
    handler names whose descriptor policy declares a static read-only hint. *)
val readonly_internal_names : unit -> string list

(** Descriptor-owned inline-safe projection. The returned names are internal
    MASC tools safe for keeper use without an MCP session context. *)
val keeper_safe_inline_names : unit -> string list

(** Descriptor-owned projection for read-only tools whose legitimate progress
    is polling a prior async request rather than taking a new snapshot. *)
val polling_read_internal_names : unit -> string list

val public_input_schema : string -> Yojson.Safe.t option
val translate_input : public:string -> Yojson.Safe.t -> Yojson.Safe.t
val receipt_labels_json : t -> Yojson.Safe.t
val route_evidence_json : t -> Yojson.Safe.t

(** Read-only discovery projection for capability introspection surfaces.
    Keeps executor, policy, schema-shape, and curated typed examples attached
    to the descriptor that owns the runtime route. *)
val discovery_fields : t -> (string * Yojson.Safe.t) list

(** Object wrapper for {!discovery_fields}. *)
val discovery_json : t -> Yojson.Safe.t
