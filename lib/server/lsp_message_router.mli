(** LSP Message Router — route JSON-RPC messages between WebSocket clients
    and LSP server processes.

    Internal helpers ([build_request], [build_notification], [parse_response],
    [parse_notification], [resolve_pending], [reject_all]) are intentionally
    not exposed. *)

type pending_request = {
  client_id : int;
  method_ : string;
  promise : (Yojson.Safe.t, string) result Eio.Promise.t;
  resolver : (Yojson.Safe.t, string) result Eio.Promise.u;
}

type t

val create : unit -> t

val send_request : t ->
  Lsp_process_manager.lsp_process ->
  method_:string ->
  params:Yojson.Safe.t ->
  client_id:int ->
  (Yojson.Safe.t, string) result Eio.Promise.t

val send_notification : t ->
  Lsp_process_manager.lsp_process ->
  method_:string ->
  params:Yojson.Safe.t ->
  unit

val start_response_reader :
  sw:Eio.Switch.t ->
  t ->
  Lsp_process_manager.lsp_process ->
  on_exit:(reason:string -> unit) option ->
  on_notification:(client_id:int -> method_:string -> Yojson.Safe.t -> unit) ->
  unit
