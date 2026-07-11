(** Agent-facing tool descriptor spine.

    This module owns the schema-allowed capability names and their projection to
    internal keeper handlers.  Domain modules such as shell, GitHub, and
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

type approval =
  | No_approval
  | Policy_selected
  | Human_required

(** Semantic capability identity owned by the tool core. Nominal routes never
    merge by string similarity; closed Board operation identities intentionally
    join the external route and Keeper wrapper. *)
type capability_id = Tool_capability_id.t

(** Exactly one model projection policy per descriptor. Public descriptors
    expose their preferred public name, ordinary internal descriptors expose
    their internal name, and dispatch-only descriptors remain routable outside
    the Keeper model surface. *)
type keeper_model_projection =
  | Preferred_public_name
  | Internal_name
  | Dispatch_only

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
  | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch
  | Tool_masc_schedule_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_surface_audit
  | Tool_masc_fusion_dispatch
  | Tool_masc_fusion_status
  | Tool_analyze_image

type policy =
  { readonly_of_input : readonly_of_input
  ; readonly_hint : bool option
  ; effect_domain : Tool_catalog.effect_domain option
  ; approval : approval
  ; retryable : bool
  ; cwd_scope : string option
  ; inline_safe : bool
  ; maintenance_only : bool
  ; polling_read : bool
  }

type t =
  { id : string
  ; capability_id : capability_id
  ; keeper_model_projection : keeper_model_projection
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
val approval_to_string : approval -> string
val runtime_handler_to_string : runtime_handler -> string
val capability_id_to_string : capability_id -> string
val equal_capability_id : capability_id -> capability_id -> bool
val compare_capability_id : capability_id -> capability_id -> int
val keeper_model_projection_to_string : keeper_model_projection -> string

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

(** [model_visible_descriptors ()] is the descriptor set with a non-empty
    Keeper model projection. The projection is the sole Keeper-plane exposure
    authority; external catalog visibility remains owned by [Tool_catalog]. *)
val model_visible_descriptors : unit -> t list

(** Preferred model-facing name for this descriptor. The list is empty for a
    dispatch-only route and otherwise contains exactly one name. *)
val keeper_model_names : t -> string list

(** Keeper candidate/execution names owned by the descriptor. Public aliases
    are deliberately excluded: the preferred public name and the internal
    route are sufficient. Dispatch-only descriptors return an empty list. *)
val keeper_candidate_names : t -> string list

(** Whether the descriptor's internal route belongs to the MASC front-door
    family. This typed handler classification replaces name-prefix tests. *)
val is_masc_internal_route : t -> bool

val public_names_of_descriptor : t -> string list
(** Legacy-routable public names, including compatibility aliases. Do not use
    this list to construct a model schema; use [keeper_model_names]. *)

val public_names : unit -> string list
(** Active preferred model names for [public_descriptors]. *)
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

(** Descriptor-owned maintenance-only projection. The returned names are
    internal MASC tools excluded from ordinary keeper candidate sets. *)
val keeper_maintenance_only_names : unit -> string list

(** Descriptor-owned projection for read-only tools whose legitimate progress
    is polling a prior async request rather than taking a new snapshot. *)
val polling_read_internal_names : unit -> string list

val public_input_schema : string -> Yojson.Safe.t option
val translate_input : public:string -> Yojson.Safe.t -> Yojson.Safe.t
val receipt_labels_json : t -> Yojson.Safe.t
val route_evidence_json : t -> Yojson.Safe.t

(** Read-only discovery projection for capability introspection surfaces.
    Keeps executor, policy, schema-shape, and curated typed examples attached
    to the descriptor that owns the runtime route. The policy [effect_domain] is
    [null] when a descriptor has no static effect domain; no fallback sentinel
    string is emitted. *)
val discovery_fields : t -> (string * Yojson.Safe.t) list

(** Object wrapper for {!discovery_fields}. *)
val discovery_json : t -> Yojson.Safe.t
