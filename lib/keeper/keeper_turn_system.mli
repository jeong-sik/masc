(** Keeper_turn_system — the System a keeper turn sends, and the articles
    that changed since it was rendered (RFC-0491 §3.2).

    An Agent Core request is the System, the carried history, then the end
    context. A System whose bytes change makes the provider miss the cache
    for the history behind it, and a world article written by any keeper
    changed every keeper's System on its next turn. So a keeper session keeps,
    per Agent Core runtime, the articles of the last System that runtime was
    issued while the carried range opens where the last request on that
    runtime opened: the System is rendered with them again, and the articles
    written, edited or taken back since then travel in the end context as the
    {!Prompt_block_id.Constitution_amendments} block. The System and that
    block are one value, so no caller holds a System rendered with older
    articles without the block that brings them up to date.

    Where the range opens is predicted before the turn, because Agent Core
    fixes each request's System before its projection picks the range
    ({!Keeper_next_request_forecast.first_request}). A prediction that misses
    costs the cache for that request only: the System and the block together
    always carry the articles the world holds now.

    What a session keeps ({!held}) rides the session's checkpoint
    ({!read}, {!write}), so it is as durable as the history it describes: a
    restarted server reads it back with the checkpoint, and a native
    continuation that resends its seed's recorded System reads, from the
    seed's own context, which articles those bytes were rendered with
    ({!resend}). A basis names articles by the article ledger's position
    when they were read, not by copying them: the ledger only grows, so the
    articles of that moment are the fold of its first bytes
    ({!World_constitution_store.load_articles_at}). The ledger and the
    keeper's instructions stay the source of truth; a basis whose ledger
    bytes changed, or whose rendering no longer matches its digest, is not
    used. *)

type t = private
  { text : string  (** The System's bytes. *)
  ; amendments : string option
        (** The rendered {!Prompt_block_id.Constitution_amendments} block:
            [Some] only for a System rendered with articles the world has
            since changed. *)
  ; current_norms : string option
        (** The complete current article set for native resumption or a
            projection containing isolated moves. Independent of the recorded System's basis; bounded by
            the held articles rather than all inactive ids in history. *)
  }

(** The articles a System was rendered with, the ledger position they were
    read at, and that System's SHA-256. *)
type basis

val basis :
  articles:World_constitution_types.t list ->
  at:World_constitution_store.position ->
  system:string ->
  basis
(** The basis of [system], rendered with [articles] read at [at]. *)

(** What a keeper session's checkpoint holds: the basis of the System its
    latest turn issued, and per Agent Core runtime the basis of the last
    System issued with that runtime at the head of the walk. *)
type held

(** Where the predicted first request's range opens, against where the last
    request on the same (keeper, runtime, trace) opened. *)
type front =
  | Same_front  (** Same first atom, opened by the same message. *)
  | Moved_front
  | No_previous_request
      (** The pair has no ledger, the history no longer holds it, or its last
          request carried no atom. *)

val front :
  digest_at:(int -> string option) ->
  first_atom:int ->
  previous:Keeper_carried_front.seed option ->
  front
(** Pure. [first_atom] is the predicted range's first atom and [digest_at]
    reads the history it is an index of; [previous] is
    {!Keeper_next_request_forecast.first_request.ledger_front}. *)

type decision =
  | From_basis of
      { text : string
      ; amendments : World_constitution_render.amendments option
      ; basis : basis
      }
      (** The range keeps its front and [basis] renders to the bytes it
          recorded: the System is rendered with its articles. *)
  | From_current of { text : string }  (** Rendered with the articles held now. *)

val decide :
  front:front ->
  basis:basis option ->
  render:(World_constitution_types.t list -> string) ->
  current:World_constitution_types.t list ->
  decision
(** Pure. [From_basis] when [front] is [Same_front], [basis] is present and
    [render] of its articles has its digest; otherwise [From_current]. A
    keeper instruction or [keeper.md] edit therefore renders the System with
    the current articles on the turn it is first read: the bytes changed and
    the history cache is lost either way. *)

(** Who composes the turn's first request: the head of the walk the turn
    takes. A later candidate of the same walk receives the same System and
    block. Claude Code passes the System on every run and Codex sends a
    changed System again on resume, so either holds what the block amends.
    Every line of the block is true of the world now whatever System it
    reaches; only its sum names the current articles exactly when the
    receiver holds this System. *)
type lane =
  | Agent_core of
      { runtime_id : string
      ; front : front
      }
      (** An Agent Core runtime: masc fixes the System of each request. *)
  | Without_basis
      (** An official client, whose vendor session holds its own System
          (RFC-0491 §5), or a runtime the catalog does not hold. *)

val issue :
  held:held option ->
  lane:lane ->
  render:(World_constitution_types.t list -> string) ->
  current:World_constitution_types.t list ->
  at:World_constitution_store.position ->
  articles_at:(World_constitution_store.position -> (World_constitution_types.t list option, 'e) result) ->
  (t * held, 'e) result
(** {!decide} over [held]'s basis for an [Agent_core] lane's runtime, its
    articles read back through [articles_at]; [From_current] records
    [current], read at [at], as that runtime's new basis. [Without_basis]
    renders [current] and keeps the runtime bases as they were. The returned
    [held] names the System issued, for the turn to {!write} into the context
    its checkpoint persists. An [articles_at] error is returned as is. Raises
    [Invalid_argument] when [render] or the block's prompt slot does. *)

val resend :
  held:held option ->
  runtime_id:string ->
  current:World_constitution_types.t list ->
  articles_at:(World_constitution_store.position -> (World_constitution_types.t list option, 'e) result) ->
  string ->
  (t * held option, 'e) result
(** The System a native continuation sends: the bytes its seed recorded,
    with [held] read from that seed's checkpoint. When [held]'s issued basis
    rendered those bytes and its articles read back, the block names what
    changed since, and [runtime_id] now holds that basis. Otherwise which
    articles rendered the bytes is not known and no ordinary delta is issued.
    The turn preparer attaches {!with_current_norms} for every native seed,
    independently of whether this historical basis could be reconstructed. *)

val with_current_norms : World_constitution_types.t list -> t -> t
(** Replace ordinary amendments with the complete current article set from
    {!World_constitution_store.load_held}, including an empty set. The System
    bytes and basis stay exact. Does not approve any isolated move. *)

val with_bytes : issued:t -> string -> t
(** The System a request sends when a hook overrides the bytes {!issue}
    gave: [issued] when they are its own, otherwise those bytes with no
    ordinary amendments, since which articles rendered them is not known.
    The complete current norms remain true for any System and are preserved. *)

val read : Agent_core.Context.t -> (held option, string) result
(** What a session context holds. [Ok None] when nothing was written, as in
    a session's first turn. A malformed entry is an [Error]. *)

val write : Agent_core.Context.t -> held -> unit
(** Writes [held] into the session scope of the context a turn's checkpoint
    persists. *)
