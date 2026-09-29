(** Strict reading of ledger rows, shared by the Candle modules.

    A row is a JSON object read field by field. A field is taken out of the
    remaining list once, so a field the reader never asked for is left over and
    {!finish} refuses it. A missing field, a repeated field, a field of the wrong
    JSON kind and an unknown field are all errors. There is no default. *)

type fields = (string * Yojson.Safe.t) list

val object_fields : context:string -> Yojson.Safe.t -> (fields, string) result

val field :
  context:string
  -> string
  -> (Yojson.Safe.t -> ('a, string) result)
  -> fields
  -> ('a * fields, string) result
(** [field ~context key decode fields] takes [key] out of [fields] and decodes
    its value. [Error] when [key] is absent, appears twice, or [decode] refuses
    the value. *)

val finish : context:string -> fields -> (unit, string) result
(** [Error] naming the first field nobody took. *)

val as_string : Yojson.Safe.t -> (string, string) result

val as_non_blank : Yojson.Safe.t -> (string, string) result
(** A string with something in it, for identifiers. *)

val as_int : Yojson.Safe.t -> (int, string) result
val as_list : (Yojson.Safe.t -> ('a, string) result) -> Yojson.Safe.t -> ('a list, string) result

val as_nullable :
  (Yojson.Safe.t -> ('a, string) result) -> Yojson.Safe.t -> ('a option, string) result
(** [`Null] is [None]; anything else goes to the decoder. *)
