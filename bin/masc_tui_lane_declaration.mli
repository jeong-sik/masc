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
val template : string
val create : string -> (session, string) result
val editable_source_path : directory:string -> string -> bool
val from_document : document -> session
val write_json : session -> Yojson.Safe.t
val decode_response : request -> status:int -> body:string -> (response, string) result
val after_response : session -> response -> session
val use_current_revision : session -> (session, string) result
val replace_with_current : session -> (session, string) result
val summary : session -> string list
