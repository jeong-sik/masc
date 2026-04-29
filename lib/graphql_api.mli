(** Graphql_api — GraphQL HTTP entry point for the MASC dashboard.

    Exposes a single {!handle_request} that parses a JSON body
    ([{ "query": ..., "variables"?, "operationName"? }]),
    executes against the MASC GraphQL schema, and returns
    a {!response} with status + JSON-serialized body.

    Cursor codec: {!encode_cursor} / {!decode_cursor} are
    base64-encoded ["<kind>:<value>"] strings.  The [~kind]
    label binds cursors to their resource type (task / agent /
    message); cross-kind reuse fails by design.  Used by tests
    via {!encode_cursor}/{!decode_cursor} directly + by every
    [Connection.edges[].cursor] in the schema.

    Pagination defaults: {!default_first} = 50, {!max_first} =
    200.  {!clamp_first} folds [None] -> default and clamps
    [Some n] to [\[0, max_first]].

    Internal: ~25+ helpers + 5 internal types stay private —
    \[ctx] (the per-request GraphQL execution context, carrying
    [room_config]), \[page_info] / [\'a edge] / [\'a connection]
    (internal Connection-spec records used by the schema
    builders), \[task_status_info] type +
    \[task_status_info_of_task] projector, the schema typ
    definitions ([page_info_typ], [worktree_info_typ],
    [task_status_typ], [task_typ], [agent_meta_typ],
    [agent_typ], [message_typ], [room_state_typ],
    [task_edge_typ], [agent_edge_typ], etc.), and
    \[drop_after_id] (cursor-based pagination cursor
    consumption helper).  All consumed only inside the schema
    + {!handle_request}'s pipeline. *)

(** {1 Response shape} *)

type response_status = [ `OK | `Bad_request ]
(** HTTP-shaped status closure for the GraphQL response.
    Pinned 2-variant set — drift to richer error grading would
    require a coordinated update with caller status mappers
    (e.g. [http_status_of_graphql] in
    [server_routes_http_pages.ml]). *)

type response = {
  status : response_status;
  body : string;
}
(** Concrete record because callers destructure
    ([response.status], [response.body]) at the dispatch site. *)

(** {1 Pagination constants} *)

val max_first : int
(** [200].  Pinned upper bound for [first] argument across all
    Connection types.  Drift would change "max page size"
    contract reflected in the schema. *)

val default_first : int
(** [50].  Used when [first] is omitted from a Connection
    query. *)

val clamp_first : int option -> int
(** [clamp_first None] is {!default_first}.  [clamp_first
      (Some n)] is [max 0 (min n max_first)] — clamps to
    [\[0, max_first]] including non-negative coercion. *)

(** {1 List slicer} *)

val take : int -> 'a list -> 'a list
(** [take n items] returns the first [n] items (or all when
    [n >= length items]).  [n <= 0] returns []. *)

(** {1 Cursor codec} *)

val encode_cursor : kind:string -> string -> string
(** [encode_cursor ~kind value] returns the base64 encoding of
    ["<kind>:<value>"].  [kind] binds the cursor to a resource
    type (task / agent / message); reuse across kinds fails via
    {!decode_cursor}. *)

val decode_cursor : kind:string -> string -> string option
(** [decode_cursor ~kind cursor] base64-decodes [cursor] and
    returns [Some value] when the prefix matches [<kind>:],
    otherwise [None].  Pinned at the contract seam — drift to
    permissive (kind-agnostic) decoding would re-open
    cross-resource cursor confusion that the kind binding
    prevents. *)

(** {1 Request entry} *)

val handle_request : config:Coord.config -> string -> response
(** [handle_request ~config body_str] executes a GraphQL
    request:

    + Parse [body_str] as JSON object with required [query]
      string and optional [variables] / [operationName].
    + Build the per-request {!ctx} from [config] and dispatch
      against the MASC GraphQL schema.
    + Return [{ status = `OK; body = "<json>" }] on success or
      [{ status = `Bad_request; body = "<error json>" }] on
      parse / validation / execution failure.

    Never raises — every error path returns a 400-style
    response.  Callers (HTTP gateway, server routes, tests)
    map the status closure to their transport-specific HTTP
    status. *)
