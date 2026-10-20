(** Operator-only original tool-result protocol; no caller-selected raw paths
    or blob addresses. Each page repeats the exact execution and source. *)
type identity = {
  source_id : string;
  sha256 : string;
  recorded_bytes : int;
  is_error : bool;
}
type response =
  | Pending
  | Unavailable of string
  | Page of identity * Keeper_artifact_read.page
val page_envelope :
  keeper:string -> execution_id:string -> identity -> Yojson.Safe.t -> Yojson.Safe.t
val to_json : keeper:string -> execution_id:string -> response -> Yojson.Safe.t
val of_json :
  keeper:string -> execution_id:string -> Yojson.Safe.t -> (response, string) result
val bytes : Keeper_artifact_read.page -> (string, string) result
(** Base64 is decoded as bytes, not independently converted to UTF8. *)
val validate_continuation :
  offset:int -> previous:(identity * Keeper_artifact_read.page) option ->
  identity -> Keeper_artifact_read.page -> (unit, string) result
(** Identity, size, requested byte offset, byte counts, EOF and forward progress
    must agree; source changes reject the whole read, never join two sources. *)

val verify_body : identity -> Keeper_artifact_read.page -> string -> (unit, string) result
(** Verify final byte count, UTF8 and the projected body's SHA256 after byte
    concatenation. Does not infer producer output-completeness guarantees. *)
