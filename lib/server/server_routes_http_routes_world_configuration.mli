(** Token-authenticated operator access to authored world configuration.
    GET [/api/v1/world/configuration/export] returns complete configuration
    documents and observed capture warnings. The response is confidential;
    it does not activate an import or copy dependency assets. *)
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
