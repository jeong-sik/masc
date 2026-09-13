(** An explicitly attached Firefox. Closing the peer never closes its tabs or
    browser. Context IDs are owned by BiDi, not extension tab IDs. *)
type failure = Before_effect of string | Outcome_unknown of string
type t
val create : command:(string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result) -> t
val metadata : t -> (string, string) result
val dispatch : t -> verb:string -> Yojson.Safe.t -> (Yojson.Safe.t, failure) result
val with_connection : env:Eio_unix.Stdenv.base -> timeout:float -> url:string ->
  (t -> (unit, string) result) -> (unit, string) result
