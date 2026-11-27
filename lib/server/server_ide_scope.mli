(** IDE observation scope — the addressing vocabulary shared by every IDE
    read surface.

    Canonical Keeper tool-call rows carry a codebase address, so any reader
    has to say which codebase it is addressing before it can read its events.
    The REST routes take that decision from query parameters; the LSP proxy
    takes it from the same parameters on its WebSocket URL. Both resolve
    through this module so the two surfaces cannot drift into separate
    vocabularies. *)

type ide_error =
  { code : string
  ; message : string
  }

val ide_error : string -> string -> ide_error

(** One wire key. [Scope_codebase] carries the canonical slug itself — the
    codebase address on the tool-call rows and the value the co-view context
    hands the keeper. Full-URL and repo_id spellings are projection labels,
    not addresses. *)
type ide_scope = Scope_codebase of { slug : string }

val codebase_of_ide_scope : ide_scope -> string
(** The slug the scope addresses — the codebase filter on the tool-call
    rows. *)

val resolve_ide_scope_for_query
  :  state:Mcp_server.server_state
  -> uri:Uri.t
  -> (ide_scope, ide_error) result
(** Resolve [codebase] from [uri]. Absent and unresolvable scopes are
    typed errors: there is no default scope, because guessing one is how
    a reader silently addresses the wrong store. *)

val resolve_optional_ide_scope_for_query
  :  state:Mcp_server.server_state
  -> uri:Uri.t
  -> (ide_scope option, ide_error) result
(** Like {!resolve_ide_scope_for_query}, but a request that carries no scope
    parameter at all resolves to [Ok None] instead of an error.

    This exists for the LSP proxy, whose connection may legitimately want
    only language-server passthrough and no MASC overlay. [Ok None] means
    "this connection addresses no store"; it must not be collapsed into a
    default store. A malformed scope is still [Error]. *)
