(** Operator dashboard workspace descriptor extracted from [Operator_control_snapshot]. *)

val workspace_json : Workspace.config -> Yojson.Safe.t
(** Return the current workspace summary JSON for the operator dashboard. *)
