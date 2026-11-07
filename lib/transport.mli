(** Transport protocol names and the OpenAPI document of the REST surface. *)

(** Protocol type *)
type protocol =
  | JsonRpc
  | Rest
  | Grpc
  | Sse
  | Ws

val protocol_to_string : protocol -> string

(** {1 REST API} *)

module Rest : sig
  type http_method = GET | POST

  val method_to_string : http_method -> string
  val generate_openapi_document :
    ?host:string -> ?port:int -> unit -> Yojson.Safe.t
end
