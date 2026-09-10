(** Write content is either text or a verified durable artifact. Only the
    reference is serialized into approval/replay records for binary writes. *)
type t = Text of string | Artifact of Tool_output.artifact_ref | Patch_input
type error = Invalid of string | Unavailable of string
val of_args : Yojson.Safe.t -> (t, error) result
val bytes : config:Workspace.config -> t -> (string option, error) result
val fields : t -> (string * Yojson.Safe.t) list
val failure : error -> Keeper_tool_execution.t
