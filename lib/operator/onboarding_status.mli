(** Read-only first-run observations, shared by the CLI and operator HTTP UI.
    Declaration, verification and execution are separate facts. Inspecting this
    document never starts a model, creates a workspace, or changes configuration. *)
type action = Choose_workspace | Initialize_workspace | Configure_models
  | Configure_sandbox | Start_imp | Inspect_configuration

type condition = Satisfied | Needs_setup | Needs_verification | Invalid

type check =
  { id : string
  ; condition : condition
  ; message : string
  ; actions : action list
  }

type t =
  { base_path : string option
  ; checks : check list
  ; selected_runtime : string option
  ; selected_model : string option
  }

val inspect : base_path:string option -> t
val to_json : t -> Yojson.Safe.t
val to_text : t -> string
