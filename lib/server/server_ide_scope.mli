(** IDE observation scope — the addressing vocabulary shared by every IDE
    read surface.

    A [.masc-ide/] store is partitioned, so any reader has to say which
    partition it is addressing before it can name a document. The REST
    routes take that decision from query parameters; the LSP proxy takes it
    from the same parameters on its WebSocket URL. Both resolve through this
    module so the two surfaces cannot drift into separate vocabularies —
    the drift that left the LSP overlay reading [_orphan/] while keeper
    writes landed in [by-url/<slug>/]. *)

type ide_error =
  { code : string
  ; message : string
  }

val ide_error : string -> string -> ide_error

val nonempty_query_param : Uri.t -> string -> string option
(** Query parameter with surrounding whitespace trimmed, [None] when absent
    or blank. A blank scope parameter is an absent one, never a match. *)

(** RFC-0378 §5.3b: one wire key. [Scope_codebase] carries the canonical
    slug itself — the partitioned store's directory name and the value the
    co-view context hands the keeper. Full-URL and repo_id spellings are
    projection labels, not addresses, and are not scopes. *)
type ide_scope =
  | Scope_codebase of { slug : string }
  | Scope_keeper_lane of { keeper_id : string }

val partition_of_ide_scope : ide_scope -> Ide_paths.partition
(** The store partition the scope addresses. *)

val resolve_ide_scope_for_query
  :  state:Mcp_server.server_state
  -> uri:Uri.t
  -> (ide_scope, ide_error) result
(** Resolve exactly one of [codebase] / [keeper_lane] from [uri]. Absent,
    conflicting, and unresolvable scopes are all typed errors: there is no
    default scope, because guessing one is how a reader silently addresses
    the wrong partition. *)

val resolve_optional_ide_scope_for_query
  :  state:Mcp_server.server_state
  -> uri:Uri.t
  -> (ide_scope option, ide_error) result
(** Like {!resolve_ide_scope_for_query}, but a request that carries no scope
    parameter at all resolves to [Ok None] instead of an error.

    This exists for the LSP proxy, whose connection may legitimately want
    only language-server passthrough and no MASC overlay. [Ok None] means
    "this connection addresses no store"; it must not be collapsed into a
    default partition. A malformed scope is still [Error]. *)
