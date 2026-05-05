(** Transport Layer - Protocol Bindings Abstraction *)

(** {1 Request/Response Types} *)

type request = {
  id: string option;
  method_name: string;
  params: Yojson.Safe.t;
  headers: (string * string) list;
}

type response = {
  id: string option;
  success: bool;
  result: Yojson.Safe.t option;
  error: error option;
}

and error = {
  code: int;
  message: string;
  data: Yojson.Safe.t option;
}

(** Protocol type *)
type protocol =
  | JsonRpc
  | Rest
  | Grpc
  | Sse
  | Ws
  | Webrtc

val protocol_to_string : protocol -> string
val protocol_of_string : string -> protocol option

(** Transport binding configuration *)
type binding = {
  protocol: protocol;
  url: string;
  options: (string * string) list;
}

(** {1 Error Codes} *)

module ErrorCodes : sig
  val parse_error : int
  val invalid_request : int
  val method_not_found : int
  val invalid_params : int
  val internal_error : int
  val server_error : int
  val not_initialized : int
  val task_not_found : int
  val permission_denied : int
end

(** {1 Response Constructors} *)

val make_error :
  ?id:string -> ?data:Yojson.Safe.t option -> code:int -> message:string -> unit -> response

val make_success :
  ?id:string -> result:Yojson.Safe.t -> unit -> response

(** {1 JSON-RPC 2.0} *)

module JsonRpc : sig
  val version : string
  val parse_request : Yojson.Safe.t -> (request, string) result
  val serialize_response : response -> Yojson.Safe.t
  val make_request :
    ?id:string -> method_name:string -> params:Yojson.Safe.t -> unit -> Yojson.Safe.t
end

(** {1 REST API} *)

module Rest : sig
  type http_method = GET | POST | PUT | DELETE | PATCH

  val method_to_string : http_method -> string
  val tool_to_endpoint : string -> http_method * string
  val parse_request :
    http_method:string ->
    path:string ->
    query_params:(string * Yojson.Safe.t) list ->
    body:string ->
    request
  val generate_openapi_paths : unit -> Yojson.Safe.t
  val generate_openapi_document :
    ?host:string -> ?port:int -> unit -> Yojson.Safe.t
  val operation_catalog_entry :
    string -> Masc_domain.tool_schema -> Yojson.Safe.t
end

(** {1 Bindings} *)

val get_bindings : host:string -> port:int -> binding list
val bindings_to_json : binding list -> Yojson.Safe.t

(** {1 Statistics} *)

module Stats : sig
  val record_request : success:bool -> latency_ms:int -> unit
  val get_stats : unit -> Yojson.Safe.t
  val reset : unit -> unit
end
