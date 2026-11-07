(** Keeper chat history for the dashboard: the tail window, the exact pages, and the
    Skill activation projection attached to their rows. *)

val attach_keeper_chat_skill_activations :
  config:Workspace.config -> keeper_name:string -> Yojson.Safe.t -> Yojson.Safe.t
(** Attach the exact-turn Skill activation projection to assistant chat rows.
    A row that reports [keeper_skill] but has no matching retained activation
    receives an explicit missing/unavailable status; no timestamp or row-order
    inference is used. Exposed so the server JSON contract can be tested
    without opening an HTTP listener. *)

val keeper_chat_history_json :
  Workspace.config -> string ->
  (Yojson.Safe.t, Server_keeper_chat_history_read.error) result
(** Body for [GET /chat/history]: the chat-store tail window plus every
    autonomous turn retention still holds. Every row carries a stable [id] —
    the dashboard history schema silently drops rows without one. *)

val keeper_chat_history_page_json :
  ?max_total:int -> Workspace.config -> string ->
  cursor:Keeper_chat_history_page.cursor option ->
  (Yojson.Safe.t, Keeper_chat_history_page.error) result
(** Exact direct-conversation pages in append order. The v2 envelope's
    [next_cursor] is an opaque descriptor/offset/anchor identity, or null when
    exhausted. Row timestamps remain display observations and never control
    paging. Autonomous rows remain on the transcript route. A stale file or
    malformed row refuses the entire page rather than advancing its cursor. *)

val handle_page_get :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/chat/history/page] with one page of
    [keeper_chat_history_page_json]. A missing or invalid keeper name, cursor or
    limit answers 400, a stale cursor 409, and a malformed or oversize row or an
    I/O error 500. *)

val handle_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/chat/history] with the cached
    [keeper_chat_history_json] body, built on the CPU executor. A missing or
    invalid keeper name answers 400, an unknown keeper 404 and an unreadable
    history 503. *)
