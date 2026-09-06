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
  | Host_sandbox_roots
  | Turn_sandbox
  | Docker_profile
  | Backend_selected

(** One explicit Keeper-model exposure choice per descriptor. Compatibility
    aliases remain routable at transport boundaries but never become a second
    model-facing name. [Operator_only] keeps an operator descriptor
    available to trusted operator entrypoints without exposing it to the
    autonomous Keeper model. [Transport_alias] identifies a descriptor whose
    exact capability is already projected by another descriptor. *)
type keeper_model_projection =
  | Preferred_public_name
  | Internal_name
  | Operator_only
  | Transport_alias of { projected_by : string }

(** Typed display group for Keeper capability discovery. *)

(** Provenance of the descriptor input schema. A missing canonical cluster
    schema excludes that descriptor from model projection and is reported by
    the schema injection boundary. *)
type input_schema_source =
  | Descriptor_owned
  | Canonical_registry
  | Keeper_projection

type readonly_of_input = Yojson.Safe.t -> bool option

type ordinary_execution_mode =
  | Serial
  | Concurrent

type execution =
  | Ordinary of ordinary_execution_mode
  | Direct_terminal
  | Terminal
(** Descriptor-owned execution contract. Read-only classification does not
    imply concurrency safety. [Direct_terminal] ends a direct model tool turn
    after success but remains a serial, non-terminal node inside a composition;
    [Terminal] ends both. Terminal concurrent execution is not representable. *)

(** Closed execution-semantics classification of one tool call: whether the
    call is itself a multi-call execution unit (RFC-0386). [Atomic_tool] runs
    one capability per call. [Composition_tool] runs one fixed, validated
    catalog plan inline. [Async_composition_tool] covers durable async
    composition submissions and their status/cancel controls. This
    axis is orthogonal to {!execution}: kind classifies what a call contains,
    execution classifies how that call runs. *)
type tool_kind =
  | Atomic_tool
  | Composition_tool
  | Async_composition_tool

(** Descriptor-owned output contract for typed composition. [Opaque_output]
    cannot be referenced by another plan node. [Json_output] carries a schema
    in the closed composable-output subset checked by [Keeper_tool_plan.create]:
    exact JSON types, object properties/required/boolean additionalProperties,
    and homogeneous array items. Unsupported JSON Schema keywords fail closed. *)
type composable_output =
  | Opaque_output
  | Json_output of { schema : Yojson.Safe.t }

type identity_validation =
  | Validate_once_before_translation
  | Validate_once_after_translation
(** Validation owner for translations that preserve the public schema. Exactly
    one descriptor validation boundary is selected. *)

type shape_changing_validation =
  | Validate_before_and_after_translation
  | Validate_before_then_runtime_handler
(** Validation owner for shape-changing translations. Public input is always
    validated before translation; the translated shape is then validated by
    either the descriptor schema or the runtime handler's typed boundary. *)

type input_translation =
  | Identity of identity_validation
  | Shape_changing of
      { translate : Yojson.Safe.t -> Yojson.Safe.t
      ; validation : shape_changing_validation
      }

type runtime_handler =
  | Tool_execute
  | Tool_search_files
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_time_now
  | Tool_lane_status
  | Tool_tools_list
  | Tool_capability_search
  | Tool_context_status
  | Tool_artifact_read
  | Tool_memory_search
  | Tool_memory_retract
  | Tool_memory_write
  | Tool_library_search
  | Tool_library_read
  | Tool_surface_read
  | Tool_surface_post
  | Tool_person_note_set
  | Tool_ide_annotate
  | Tool_voice_dispatch
  | Tool_task_dispatch
  | Tool_board_dispatch
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
  | Tool_keeper_spawn_dispatch
  | Tool_keeper_code_query_dispatch
  | Tool_keeper_webmcp_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_fusion_dispatch
  | Tool_masc_fusion_status
  | Tool_masc_library_dispatch
  | Tool_masc_local_runtime_dispatch
  | Tool_analyze_image

type policy =
  { readonly_of_input : readonly_of_input
  ; readonly_hint : bool option
  ; cwd_scope : string option
  ; polling_read : bool
  ; leaves_masc : bool
      (** Whether a call that is not a read reaches past masc's own stores —
          the sandbox filesystem, a process, a service. A write that only
          moves masc's durable rows (a memory entry, a board post, a surface
          row) is visible and undoable inside the workspace, so the approval
          policy runs it; anything that leaves is asked about. Declared per
          descriptor rather than derived from [cwd_scope], which answers a
          different question and would make this gate quietly wrong the day
          a sandbox-scoped read-only tool appears. *)
  }

type t =
  { id : string
  ; capability_id : string
  ; keeper_model_projection : keeper_model_projection
  ; input_schema_source : input_schema_source
  ; public_name : string
  ; internal_name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; model_output_projection : Tool_output.model_projection
  ; composable_output : composable_output
  ; execution : execution
  ; tool_kind : tool_kind
  ; policy : policy
  ; executor : executor
  ; backend : backend
  ; sandbox : sandbox
  ; runtime_handler : runtime_handler
  ; input_translation : input_translation
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


val runtime_handler_to_string : runtime_handler -> string
val tool_kind_to_string : tool_kind -> string

(** Strict parse of {!tool_kind_to_string} output. Unknown strings are an
    error, never a fallback classification. *)
val tool_kind_of_string : string -> (tool_kind, string) result

(** [public_descriptors] is the LLM-native public surface. Each descriptor has
    exactly one [public_name]. *)
val public_descriptors : t list

(** [all_descriptors ()] is [public_descriptors] plus the module-private
    descriptor-backed workspace surface (RFC-0179; [keeper_*] / [masc_*]
    workspace tools mapped to a typed handler, not part of the LLM-native
    public-name contract). The runtime dispatcher walks this list to
    resolve [internal_name] for any descriptor-backed tool, regardless of
    LLM-native vs workspace origin. *)
val all_descriptors : unit -> t list

(** Resolve the process-owned canonical descriptor for [id]. Callers that
    accept descriptor records from another layer must resolve through this
    function before treating execution, schema, or policy fields as runtime
    authority. *)
val find_id : string -> t option

(** Objective schema-shape errors for a model-facing input schema. The schema
    must be an object and every structural field must pass the same validator
    used by descriptor projection. *)
val model_input_schema_errors
  :  tool_name:string
  -> Yojson.Safe.t
  -> string list

(** Objective schema-shape errors that prevent model projection. Empty means
    the descriptor has a resolved object schema whose structural fields are
    well-formed. *)
val model_schema_errors : t -> string list

(** Descriptors with one explicit model-facing projection and a resolved input
    schema. Operator-only controls, exact transport aliases, and
    missing/structurally invalid schemas are excluded. *)
val model_visible_descriptors : unit -> t list
val model_visible_schemas : unit -> Masc_domain.tool_schema list



(** The sole active Keeper model name. Empty only for an exact
    [Operator_only], [Transport_alias], or a descriptor without a resolved
    schema. *)
val keeper_model_names : t -> string list

(** Every name owned by a descriptor, including transport-alias names. This is
    for name-integrity checks, never Keeper execution admission. *)
val registered_names : t -> string list

val public_names_of_descriptor : t -> string list
val public_names : unit -> string list
val find_public : string -> t option
val public_name_for_internal : string -> string option
val public_descriptors_for_internal : string -> t list

(** [descriptors_for_internal name] walks [all_descriptors ()]. Use this from
    the runtime dispatcher to support descriptor-backed workspace tools
    alongside the LLM-native descriptors. *)
val descriptors_for_internal : string -> t list

val readonly_static_hint : t -> bool option
val readonly_for_input : t -> input:Yojson.Safe.t -> bool option
val translate_input_for_descriptor : t -> Yojson.Safe.t -> Yojson.Safe.t

(** Descriptor-owned read-only projection. The returned names are internal
    handler names whose descriptor policy declares a static read-only hint. *)
val readonly_internal_names : unit -> string list

val translate_input : public:string -> Yojson.Safe.t -> Yojson.Safe.t
val route_evidence_json : t -> Yojson.Safe.t

(** Read-only discovery projection for capability introspection surfaces.
    Keeps executor, policy, schema-shape, and curated typed examples attached
    to the descriptor that owns the runtime route. *)
val discovery_fields : t -> (string * Yojson.Safe.t) list
