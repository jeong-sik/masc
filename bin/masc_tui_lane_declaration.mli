(** TOML documents shared by the TUI, Dashboard and Keeper declaration owner.
    Drafts are local UI state; only explicit Save sends them to the server. *)
type document = {
  file_name : string; source_path : string; source_text : string;
  source_revision : string; desired_revision : string option;
  valid : bool; messages : string list;
}
type failure_code = Invalid_request | Not_found | Revision_conflict | Invalid_declaration | Io_error
type failure = { code : failure_code; message : string; current : document option }
type write_state = Created | Saved | Unchanged
type durability = Durable | Unconfirmed of string
type receipt = { document : document; state : write_state; durability : durability }
type session = {
  file_name : string; base : document option; current : document option;
  text : string; message : string option;
}
type request = Read of string | Save of session
type response = Read_document of document | Written of receipt | Rejected of failure
val draft_enabled : session -> (bool, string) result
(** Desired activity in the draft; not observed worker state. The accepting
    deployment stage reads an absent key as enabled. Invalid TOML is an error. *)
val toggle_enabled : session -> (session, string) result
(** Change only the root enabled key in the local draft. No save or cleanup. *)
val template : string
val create : string -> (session, string) result
val editable_source_path : directory:string -> string -> bool
(** Reuse only a draft whose known source is the requested full path. A
    different path or an unbound create-only draft is a conflict. Explicit
    re-reading of a create draft may supply its owner's [create_directory];
    only that direct-child path can then receive the comparison. *)
val find_for_path : ?create_directory:string -> path:string -> session list -> (session option, string) result
val from_document : document -> session
val write_json : session -> Yojson.Safe.t
val decode_response : request -> status:int -> body:string -> (response, string) result
val after_response : session -> response -> session
val use_current_revision : session -> (session, string) result
val replace_with_current : session -> (session, string) result
val summary : session -> string list
