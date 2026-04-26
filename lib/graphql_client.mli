(** GraphQL Client — typed interface to second-brain-graphql server. *)

(** {1 Configuration} *)

val graphql_url : unit -> string

(** {1 HTTP Transport} *)

val request : ?timeout_sec:float -> ?fallback:bool -> string -> (string, string) result

(** {1 GraphQL Response Parsing} *)

val parse_response : string -> (Yojson.Safe.t, string) result

(** {1 Public API} *)

val build_body : query:string -> ?variables:Yojson.Safe.t -> unit -> string

val query
  :  ?timeout_sec:float
  -> query:string
  -> ?variables:Yojson.Safe.t
  -> unit
  -> (Yojson.Safe.t, string) result

val mutate
  :  ?timeout_sec:float
  -> mutation:string
  -> ?variables:Yojson.Safe.t
  -> unit
  -> (Yojson.Safe.t, string) result

val extract_mutation_result
  :  string
  -> Yojson.Safe.t
  -> (bool * string option, string) result
