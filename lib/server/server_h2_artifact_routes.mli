(** HTTP/2 transport for the same published-artifact and shared-draft
    operations served by the HTTP/1 router. Admission is owned by the gateway. *)
type admission =
  { with_token : permission:Masc_domain.permission ->
      (Mcp_server.server_state -> string -> (string * string) list -> unit) -> unit
  ; with_public :
      (Mcp_server.server_state -> string option -> (string * string) list -> unit) -> unit
  ; read_body : (string -> unit) -> unit
  ; refuse_auth : Masc_domain.masc_error -> unit
  }

val dispatch :
  request_sw:Eio.Switch.t ->
  h2_reqd:H2.Reqd.t ->
  request:Httpun.Request.t ->
  path:string ->
  cors:(string * string) list ->
  admission:admission ->
  [ `GET | `POST | `DELETE | `OPTIONS | `PUT | `HEAD
  | `CONNECT | `TRACE | `Other of string ] -> bool
(** Returns [true] for a matched route after invoking the appropriate gateway
    admission wrapper. The caller must perform workspace header admission and
    bind the H2 response-resource scope before dispatch. *)
