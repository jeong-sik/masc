(** Trusted private Browser companion wire; never a model tool/schema. *)
type command =
  | Prepare of { operation_id:string; tab_id:int; extension_id:string;
      directory:string; program:string; arguments:Yojson.Safe.t }
  | Invoke of { operation_id:string; program:string; arguments:Yojson.Safe.t }
  | Release of string
type error = Not_started | Outcome_unknown
val to_json : command -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (command, unit) result
(** Closed canonical request. Errors never contain input/program/secret text. *)
