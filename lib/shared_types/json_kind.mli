(** The name of a JSON value's kind, for diagnostics.

    A yojson-only micro-leaf so that every library which classifies a value
    it did not expect can say what it got, without taking [masc_core]'s
    edges to do it. The isolation those libraries keep (RFC-0056) is real,
    and the answer to it is one small dependency rather than one copy of
    this mapping per library -- there were seven, and one of them renamed
    itself to slip the lint that counts them. *)

val name : Yojson.Safe.t -> string
(** ["null"], ["bool"], ["int"], ["intlit"], ["float"], ["string"],
    ["object"], ["array"]. The JSON type names, not OCaml's constructor
    names: this text reaches an operator reading why a field was refused. *)
