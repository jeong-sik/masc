(** The JSON object a route reads from its request body. *)

val fields : string -> ((string * Yojson.Safe.t) list, string) result
(** The members of the body in order. [Error] carries the sentence the route
    answers with: [invalid json: <parser detail>] when the text does not parse,
    and [JSON object body required] when it parses to anything but an object. *)
