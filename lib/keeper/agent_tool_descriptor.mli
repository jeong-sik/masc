(** Agent-facing tool descriptor spine.

    This module owns the model-facing capability names and their projection to
    internal keeper handlers.  Domain modules such as shell, GitHub, and
    filesystem remain implementation details behind the descriptor-selected
    executor/backend/sandbox route. *)

type executor =
  | Shell_ir
  | Filesystem
  | Remote_mcp
  | In_process

type backend =
  | Ocaml_runtime
  | Host_process
  | Sandbox_process
  | Remote_service

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

type readonly_of_input = Yojson.Safe.t -> bool option

type runtime_handler =
  | Tool_execute
  | Tool_workspace_inspect
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_remote_mcp
  | Tool_time_now
  | Tool_stay_silent
  | Tool_tools_list
  | Tool_tool_search
  | Tool_context_status
  | Tool_memory_search
  | Tool_memory_write
  | Tool_library_search
  | Tool_library_read
  | Tool_ide_annotate
  | Tool_voice_dispatch
  | Tool_task_dispatch
  | Tool_board_dispatch
  | Tool_masc_board_dispatch
  | Tool_masc_task_dispatch
  | Tool_masc_plan_dispatch
  | Tool_masc_run_dispatch
  | Tool_masc_agent_dispatch
  | Tool_masc_coord_dispatch
  | Tool_masc_misc_dispatch
  | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch
  | Tool_masc_local_runtime_dispatch
  | Tool_masc_tool_shard_dispatch
  | Tool_masc_approval_dispatch
  | Tool_masc_persona_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_surface_audit

type policy =
  { visibility : Tool_catalog.visibility
  ; readonly_of_input : readonly_of_input
  ; readonly_hint : bool option
  ; effect_domain : Tool_catalog.effect_domain option
  ; approval : approval
  ; retryable : bool
  ; cwd_scope : string option
  ; credential_profile : string option
  }

type t =
  { id : string
  ; public_name : string
  ; internal_name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; policy : policy
  ; executor : executor
  ; backend : backend
  ; sandbox : sandbox
  ; runtime_handler : runtime_handler
  ; translate : Yojson.Safe.t -> Yojson.Safe.t
  ; receipt_labels : (string * string) list
  }

val executor_to_string : executor -> string
val backend_to_string : backend -> string
val sandbox_to_string : sandbox -> string
val approval_to_string : approval -> string
val runtime_handler_to_string : runtime_handler -> string

(** [public_descriptors] is the LLM-native public surface (RFC-0064 hard-cut, 7
    entries pinned by [test_alias_table_is_stable]). *)
val public_descriptors : t list

(** [internal_descriptors] is the descriptor-backed coordination surface
    (RFC-0179). Starts empty; each cluster migration PR adds entries that map
    [keeper_*] / [masc_*] coordination tools to a typed handler. Not part of
    the LLM-native public-name contract. *)
val internal_descriptors : t list

(** [all_descriptors ()] is [public_descriptors @ internal_descriptors]. The
    runtime dispatcher walks this list to resolve [internal_name] for any
    descriptor-backed tool, regardless of LLM-native vs coordination origin. *)
val all_descriptors : unit -> t list

val public_names : unit -> string list
val internal_names : t -> string list
val find_public : string -> t option
val public_name_for_internal : string -> string option
val public_descriptors_for_internal : string -> t list

(** [descriptors_for_internal name] walks [all_descriptors ()]. Use this from
    the runtime dispatcher to support descriptor-backed coordination tools
    alongside the seven LLM-native descriptors. *)
val descriptors_for_internal : string -> t list

val readonly_static_hint : t -> bool option
val readonly_for_input : t -> input:Yojson.Safe.t -> bool option

(** Descriptor-owned read-only projection. The returned names are internal
    handler names whose descriptor policy declares a static read-only hint. *)
val readonly_internal_names : unit -> string list

val public_input_schema : string -> Yojson.Safe.t option
val translate_input : public:string -> Yojson.Safe.t -> Yojson.Safe.t
val receipt_labels_json : t -> Yojson.Safe.t
val route_evidence_json : t -> Yojson.Safe.t
