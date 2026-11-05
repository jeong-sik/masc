(** Keeper_turn_system — the System a keeper turn sends, and the articles
    that changed since it was rendered (RFC-0491 §3.2).

    An Agent Core request is the System, the carried history, then the end
    context. A System whose bytes change makes the provider miss the cache
    for the history behind it, and a world article written by any keeper
    changed every keeper's System on its next turn. So a keeper keeps the
    articles its System was rendered with while the carried range opens where
    the last request on that runtime opened: the System is rendered with them
    again, and the articles written or taken back since then travel in the
    end context as the {!Prompt_block_id.Constitution_amendments} block. The
    System and that block are one value, so no caller holds a System rendered
    with older articles without the block that brings them up to date.

    Where the range opens is predicted before the turn, because Agent Core
    fixes each request's System before its projection picks the range
    ({!Keeper_next_request_forecast.first_request}). A prediction that misses
    costs the cache for that request only: the System and the block together
    always carry the articles the world holds now.

    What a keeper keeps is process memory, one entry per base path and
    keeper. The article ledger and the keeper's instructions are the source
    of truth and the entry is their projection; a restarted server renders
    its first System with the articles held then. *)

type t = private
  { text : string  (** The System's bytes. *)
  ; amendments : string option
        (** The rendered {!Prompt_block_id.Constitution_amendments} block:
            [Some] only for a System rendered with articles the world has
            since changed. *)
  }

(** The articles a System was rendered with and that System's SHA-256. *)
type basis

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
      }
      (** The range keeps its front and the basis renders to the bytes it
          recorded: the System is rendered with the basis articles. *)
  | From_current of
      { text : string
      ; basis : basis
      }
      (** Rendered with the articles held now; [basis] replaces the keeper's. *)

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

(** Who composes the turn's first request. *)
type lane =
  | Agent_core of front
      (** An Agent Core runtime: masc fixes the System of each request. *)
  | Without_basis
      (** An official client, whose vendor session holds its own System
          (RFC-0491 §5), or a runtime the catalog does not hold. *)

val issue :
  base_path:string ->
  keeper_name:string ->
  lane:lane ->
  render:(World_constitution_types.t list -> string) ->
  current:World_constitution_types.t list ->
  t
(** {!decide} over the keeper's basis for an [Agent_core] lane, storing the
    new basis on [From_current]. [Without_basis] renders [current] and
    neither reads nor writes a basis. Raises [Invalid_argument] when [render]
    or the block's prompt slot does. *)

val with_bytes : issued:t -> string -> t
(** The System a request sends when its bytes come from elsewhere than
    {!issue}: a native continuation's recorded System, or a hook's override.
    [issued] when the bytes are its own, otherwise those bytes with no
    amendments, since which articles rendered them is not known. *)
