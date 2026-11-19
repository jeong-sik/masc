(** Readers the turn log's codecs share. *)

open Keeper_memory_os_types

(** The value of [values] whose token is the text of [field]. *)
val of_token
  :  token_of:('a -> string)
  -> 'a list
  -> string
  -> (string * Yojson.Safe.t) list
  -> ('a, wire_error) result

val object_fields : Yojson.Safe.t -> ((string * Yojson.Safe.t) list, wire_error) result

(** Every element of the array [field], each refusal placed at its index. *)
val list_field
  :  string
  -> (string * Yojson.Safe.t) list
  -> (Yojson.Safe.t -> ('a, wire_error) result)
  -> ('a list, wire_error) result
