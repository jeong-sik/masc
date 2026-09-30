(** Server_refusal — the body a refused HTTP request answers with.

    [{"error": sentence}], with ["code": code] when a client branches on the
    refusal, then any fields that route adds. [error] is always the sentence a
    person reads: the TUI shows it after the status
    ([Tui_decode.http_status_error]) and the dashboard prints it. A client that
    acts on a refusal reads [code], never the sentence. *)

val json :
  ?code:string -> ?fields:(string * Yojson.Safe.t) list -> string -> Yojson.Safe.t
