(** Configuration-preserving Exact activity draft. No I/O or model dispatch. *)
type owner = { workspace : string * string; lane : Standalone_lane.t }
type document = Masc_tui_runtime_config_edit.document
type t
type request
type write = { source_text : string; expected_source_path : string; expected_source_revision : string }
type write_result =
  | Saved of Masc_tui_runtime_config_receipt.t
  | Conflict of document
  | Refused of string
  | Unconfirmed of string

val create : owner -> t
val owner : t -> owner
val request_owner : request -> owner
val same_owner : owner -> owner -> bool
val busy : t -> bool
val suspend : t -> t
(** Withdraw read authority and pending callbacks; retain the activity draft.
    A fresh read is required even when returning to the same workspace. *)
val start_read : generation:int -> t -> (t * request) option
val finish_read : request -> (document, string) result -> t -> t
val toggle : t -> t
val reapply : t -> t
(** Explicitly apply only the desired activity to the displayed current file.
    Other current settings are preserved; a different file path is refused. *)
val discard : t -> t
val start_save : generation:int -> t -> (t * request * write, string) result
val finish_save : request -> write_result -> t -> t
val lines : t -> string list
val matches : request -> t -> bool
