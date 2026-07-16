(** GraphQL Client — typed interface to second-brain-graphql server. *)

(** {1 Configuration} *)

val graphql_url : unit -> string

(** {1 HTTP Transport} *)

val request : ?timeout_sec:float -> ?fallback:bool -> string -> (string, string) result

module For_testing : sig
  val is_transport_error : string -> bool

  val response_of_curl_process_result
    :  Unix.process_status * string
    -> (string, string) result
end

(** {1 GraphQL Response Parsing} *)

(** Validate that the HTTP body is non-empty and looks like JSON.
    Returns [Error "empty response"] for empty bodies and
    [Error "endpoint returned HTML instead of JSON"] for HTML responses. *)
val ensure_json_response : string -> (string, string) result

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
