(** Typed boundary to the shared-source transformer. The caller owns document
    identity, authentication and durable commit. No actor or path enters the
    transformer command. *)
type selection = { anchor : int list; head : int list }
type snapshot = { state : string; content : string }
type positioned = { snapshot : snapshot; selection : selection; anchor : int; head : int }
type error_kind = Invalid_request | Invalid_document | Invalid_selection | Changed_selection | Unavailable
type error = { kind : error_kind; message : string }
type runner = string -> (Unix.process_status * string, string) result

val error_message : error -> string
val selection_to_json : selection -> Yojson.Safe.t
val selection_of_json : Yojson.Safe.t -> (selection, string) result
val valid_state : string -> bool
val selected_text : positioned -> (string, error) result
val default_runner : ?executable:string -> string -> (Unix.process_status * string, string) result
(** Runs the transformer with a 30 second wall-clock budget. A transformer
    that exceeds it surfaces as an [Unavailable] error, not as a document
    refusal, so the client can retry. *)
val seed : ?runner:runner -> string -> (snapshot, error) result
val merge : ?runner:runner -> state:string -> updates:string list -> unit -> (snapshot, error) result
val select : ?runner:runner -> state:string -> anchor:int -> head:int -> unit -> (positioned, error) result
val resolve : ?runner:runner -> state:string -> selection:selection -> unit -> (positioned, error) result
val edit : ?runner:runner -> state:string -> selection:selection -> expected:string -> replacement:string -> unit -> (positioned, error) result
