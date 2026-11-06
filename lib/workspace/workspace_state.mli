(** Workspace state — backlog, workspace state, and recovery helpers. *)


val normalized_string_list : string list -> string list

val write_state :
  Workspace_utils_backend_setup.config -> Masc_domain.workspace_state -> unit

val read_state : Workspace_utils_backend_setup.config -> Masc_domain.workspace_state

val update_state :
  Workspace_utils_backend_setup.config ->
  (Masc_domain.workspace_state -> Masc_domain.workspace_state) ->
  Masc_domain.workspace_state

val next_seq : Workspace_utils_backend_setup.config -> int

val take : int -> 'a list -> 'a list
