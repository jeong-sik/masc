(** Agent-facing tool descriptor spine.

    This module owns the model-facing capability names and their projection to
    internal keeper handlers.  Domain modules such as shell, GitHub, and
    filesystem remain implementation details behind the descriptor-selected
    executor/backend/sandbox route. *)

type executor =
  | In_process
  | Shell_ir
  | Gh_cli
  | Filesystem
  | Remote_mcp
  | Oas_bridge

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

type runtime_handler =
  | Tool_execute
  | Tool_search_files
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_remote_mcp

type policy =
  { visibility : Tool_catalog.visibility
  ; readonly : bool option
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

val public_descriptors : t list
val public_names : unit -> string list
val find_public : string -> t option
val public_name_for_internal : string -> string option
val public_descriptors_for_internal : string -> t list
val public_input_schema : string -> Yojson.Safe.t option
val translate_input : public:string -> Yojson.Safe.t -> Yojson.Safe.t
val route_evidence_json : t -> Yojson.Safe.t
