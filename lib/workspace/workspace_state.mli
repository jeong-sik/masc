(** Workspace state — backlog, workspace state, and recovery helpers. *)


val normalized_string_list : string list -> string list

val write_state :
  Workspace_utils_backend_setup.config -> Masc_domain.workspace_state -> unit

val read_state : Workspace_utils_backend_setup.config -> Masc_domain.workspace_state

type state_read_error =
  | State_document_error of Workspace_utils_ops.json_doc_error
  | State_decode_error of string

val state_read_error_to_string : state_read_error -> string

val read_state_strict :
  Workspace_utils_backend_setup.config ->
  (Masc_domain.workspace_state option, state_read_error) result
(** Read without recovery, initialization or writes. [Ok None] means the
    authoritative state document is absent. Present but invalid or unreadable
    documents are errors and never grant an authoritative pause value. *)

val update_state :
  Workspace_utils_backend_setup.config ->
  (Masc_domain.workspace_state -> Masc_domain.workspace_state) ->
  Masc_domain.workspace_state

val next_seq : Workspace_utils_backend_setup.config -> int
val is_paused : Workspace_utils_backend_setup.config -> bool

val pause_info :
  Workspace_utils_backend_setup.config ->
  (string option * string option * string option) option

val take : int -> 'a list -> 'a list
