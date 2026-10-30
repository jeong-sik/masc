(** One bounded document owner for HTTP and Keeper configuration editing.
    These blocking filesystem operations run under the runtime's configuration
    serializer and a system-thread boundary. They never start workers.
    Revision conflict exclusion applies to callers sharing that serializer.
    Direct filesystem writers are not participants: the final read detects
    already-visible edits, but cannot make replacement conditional on arbitrary
    concurrent writes after that read. *)
type document = private {
  file_name : string; source_path : string; source_text : string;
  source_revision : string; desired_revision : string option;
  messages : string list;
}
type error_code = Invalid_request | Not_found | Revision_conflict | Invalid_declaration | Io_error
type error = { code : error_code; message : string; current : document option }
type expectation = Create | Save of string
type write_request = private { file_name : string; source_text : string; expected : expectation }
type write_state = Created | Saved | Unchanged
type durability = Durable | Unconfirmed of string
type receipt = private { document : document; state : write_state; durability : durability }

val read_request : Yojson.Safe.t -> (string, error) result
val write_request : Yojson.Safe.t -> (write_request, error) result
val read : directory:string -> source_path:string -> (document, error) result
val write : directory:string -> write_request -> (receipt, error) result
val document_to_json : document -> Yojson.Safe.t
val receipt_to_json : receipt -> Yojson.Safe.t
val error_to_json : error -> Yojson.Safe.t

module For_testing : sig
  val write :
    replace_file:(string -> string -> (unit, Fs_compat.atomic_replace_failure) result) ->
    directory:string -> write_request -> (receipt, error) result
end
