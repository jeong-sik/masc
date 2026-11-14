(** Keeper memory reads for the dashboard: the Librarian's working context, the
    Memory-OS facts with what happened to each, and the journal tail. *)

val memory_os_dashboard_json :
  config:Workspace.config -> keeper_id:string -> Yojson.Safe.t
(** The [memory_os] field of the [/turn-records] answer: the current snapshot's
    revision, update source, facts and last change, and the read error beside
    them when the snapshot cannot be read. *)

val handle_working_context_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/working-context] with the Librarian's
    context snapshot and its SHA-256, or [present: false] when the keeper has
    none. An invalid keeper name answers 400 and an unreadable snapshot 500. *)

val handle_facts_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/memory-facts] with the ordinary and the
    source-bound fact stores, each with its own read error, and the count of
    event lines that could not be decoded. An invalid keeper name answers 400. *)

val handle_journal_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/memory-journal] with the last [limit]
    journal entries (default 50, from 1 to 500) and the count of lines this build
    cannot decode. With [activity=1], also return a bounded, read-only change
    projection, including committed absorption/revision endpoints. Ordinary
    journal reads do not read the absorption archive. An invalid keeper name
    answers 400. A journal that exists and cannot be read answers 500 with
    [read_error]. *)
