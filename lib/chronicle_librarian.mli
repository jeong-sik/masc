(** Chronicle Librarian — Master Report Dim02 P1 §2.4 (RFC-0035 PR-5).

    First slice of the Librarian Agent: an in-memory chronicle-event
    store with keyword-search retrieval that reuses the
    {!Cognitive_gravity} ranker for ordering. The full Master Report
    design (text+code embedder, vector+keyword hybrid retriever, prompt
    responder, proactive summary) is staged in later PRs; this PR
    delivers the minimum the cockpit needs to query the chronicle
    deterministically without an LLM round-trip.

    The module is intentionally pure: no I/O, no Eio, no global state.
    Persistence and replication are the host's responsibility — the
    store is an immutable value, callers pass it through their own
    state machine.

    Stack: this module sits on top of {!Chronicle_event} (PR-4) and
    {!Cognitive_gravity} (PR-1). It does not introduce any new
    dependency.

    @stability Evolving
    @since 0.19.15 *)

(** Opaque store of chronicle events. Insertion order is preserved
    internally so that ties under the search ranker resolve
    deterministically. *)
type store

(** Empty store. *)
val empty : store

(** [add s ev] returns a new store with [ev] appended at the most-recent
    end. [ev]'s well-formedness is not checked; the caller should run
    {!Chronicle_event.is_well_formed} before adding if needed. *)
val add : store -> Chronicle_event.t -> store

(** Build a store from a list. Insertion order = list order. *)
val of_list : Chronicle_event.t list -> store

(** Return all events in insertion order. *)
val to_list : store -> Chronicle_event.t list

(** Number of events in the store. *)
val len : store -> int

(** {1 Retrieval}

    The retrieval primitive is a keyword search over each event's tags
    and summary tokens, ranked by {!Cognitive_gravity.rank}. The
    [confidence] of an event scales with:

    - keyword overlap (Jaccard) between [query] and the event's
      tags ∪ summary tokens;
    - exponential recency decay relative to [now_ms] (defaults to
      the most-recent event's timestamp + 1 ms);
    - frequency weight (always 0.0 in this slice — multi-touch
      counting is a follow-up).

    The default ranker weights (`Cognitive_gravity.default_weights`)
    apply. Custom weights are not exposed yet — clients that need
    different weights should call {!Cognitive_gravity.rank} directly
    on a list built from {!to_list} and a tokeniser of their choice. *)

(** [search s ~query ?now_ms ?limit ()] ranks all events in [s]
    against [query] and returns the top [limit] paired with their
    scores. When [limit] is absent, returns the full ranking.

    The caller supplies [query] as a list of pre-split tokens. The
    function does not tokenise the query string itself — that
    responsibility is in the caller (the dashboard or a keeper) so
    different consumers can plug in different tokenisers. *)
val search :
  store ->
  query:string list ->
  ?now_ms:int ->
  ?limit:int ->
  unit ->
  (Chronicle_event.t * float) list

(** {1 Filters}

    Pure list filters preserved for callers that don't need ranking.
    All return events in insertion order. *)

val filter_by_event_type :
  store -> Chronicle_event.event_type list -> Chronicle_event.t list

val filter_by_session :
  store -> session_id:string -> Chronicle_event.t list

(** [filter_by_time_range s ~from_ms ~to_ms] returns events whose
    timestamp is in the closed interval [\[from_ms, to_ms\]]. *)
val filter_by_time_range :
  store -> from_ms:int -> to_ms:int -> Chronicle_event.t list

(** {1 Tokenisation helper}

    Exposed because the search primitive expects pre-split tokens, and
    the dashboard may want to use the same algorithm to keep
    consistency. *)

(** [tokenise text] lowercases [text], replaces every non-alphanumeric
    (and non-underscore) byte with a space, splits on whitespace, and
    drops tokens shorter than 2 characters. *)
val tokenise : string -> string list
