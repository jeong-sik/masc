(** Thin AGENT_CORE facade over {!Mcp_protocol_http.Http_client}.

    @stability Internal
    @since 0.93.1 *)

type config =
  { base_url : string
  ; headers : (string * string) list
  }

type t

val connect
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> config
  -> (t, Error.t) result

val initialize : t -> (unit, Error.t) result
val list_tools : t -> (Mcp.mcp_tool list, Error.t) result
val call_tool : t -> name:string -> arguments:Yojson.Safe.t -> Types.tool_result
val close : t -> unit

type http_spec =
  { base_url : string
  ; headers : (string * string) list
  ; name : string
  }

val connect_and_load_managed
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> http_spec
  -> (Mcp.managed, Error.t) result

val connect_and_load
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> http_spec
  -> (Mcp.managed, Error.t) result
