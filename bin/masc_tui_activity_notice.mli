(** What an activity editor (Exact lane or machine) tells the operator after
    a key or a server answer. The editor keeps the notice, not a sentence, so
    the screen can write it in either language. *)
type t =
  | Given of string
  (** Text from the server or the TOML parser, drawn as it came. *)
  | Read_failed of string
  (** The server's detail; the draft is kept. *)
  | Save_unconfirmed of string
  (** The server's detail; the current file must be read before a retry. *)
  | Saving_when_workspace_changed
  | Reading_withdrawn
  | Request_pending
  | Path_changed
  | Unread
  | Reapplied
  | Nothing_to_reapply
  | Draft_discarded_unread
  | Draft_discarded
  | File_changed_before_save
  | No_change
  | Receipt_received
  | Conflict_kept
  | Lane_undeclared
  | Lane_required
  | Lane_needs_candidate
  | Lane_declared_inline
  | Machine_declared_inline
  | Machine_edit_lost_configuration

val text : ko:bool -> t -> string
(** The sentence in Korean when [ko] is true, in English otherwise. *)
