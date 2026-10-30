(** GitHub authentication pane rows from immutable UI inputs.
    The root renderer resolves the selected Keeper's stamped base rows. *)

type view =
  { token_input : string option
  ; save_status : string option
  ; login_scopes : Masc.Keeper_github_identity.login_scope list
  }

val lines : view -> base:string list -> string list
