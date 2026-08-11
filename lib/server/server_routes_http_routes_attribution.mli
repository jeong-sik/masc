(** Server_routes_http_routes_attribution — HTTP routes and shared read
    projections for the attribution event log.

    Registers read-only routes under [/api/v1/attribution/*] for
    operator-facing event listings, gate summaries, and aggregate
    counts.  The public JSON builders are shared by the HTTP/1 and HTTP/2
    adapters so the event log's wire shape has one producer. *)

val trimmed_query_param : Httpun.Request.t -> string -> string option

val recent_json :
  ?gate:string -> ?limit:int -> unit -> Yojson.Safe.t

val summary_json : unit -> Yojson.Safe.t

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
