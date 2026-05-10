(** Server IDE LSP Proxy — WebSocket bridge for Language Server Protocol
    with MASC observational overlays. *)

(** Add LSP proxy routes to the router.
    Exposes [/api/v1/ide/lsp] WebSocket endpoint for LSP traffic. *)
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
