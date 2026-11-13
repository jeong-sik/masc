(** The bodies of the error responses the HTTP layer writes for a request no
    route answered. Each is a fixed sentence: what failed inside the server,
    an exception's text included, goes to the log and never to the client,
    since that text can name a file of the server (#50488, #50613). *)

val bad_request : string
val bad_gateway : string
val internal_server_error : string
