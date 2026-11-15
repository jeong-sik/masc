(** Shared quota/rate/failure ordering over the actual candidate observation.
    {!order} preserves every candidate and declared order within each class.
    {!order_exact} sets aside the candidates a provider asked not to be called
    yet and still returns them. Neither confers dispatch or mutation
    authority. *)

type walk_start =
  | Fresh_walk_by of Runtime_candidate_backpressure.recorder
  | Every_mark_demotes

type policy =
  | Keeper_walk of
      { start : walk_start
      ; rest_sec : retry_after:float option -> float
      }
      (** A rate observation demotes until [noted_at +. rest_sec ~retry_after]
          and orders nothing after it (RFC-provider-path-rest §3.3,
          2026-11-06). Other Keepers' failures demote, while a fresh recorder
          retries its own marks. A deferred/one-shot walk demotes every
          failure. The caller supplies its existing rest policy; this query
          invents no TTL or recorder. *)

val order :
  now:float -> policy:policy ->
  quota_scope_of:('a -> Runtime_quota_window.scope option) ->
  candidate_backpressure_of:('a -> Runtime_candidate_backpressure.candidate option) ->
  'a list -> 'a list
(** Resolve both projections from the same frozen row. Missing projections
    contribute no evidence and never remove an unresolved declared identity. *)

type 'a exact_order =
  { walk : 'a list
      (** The candidates that may be called now, declared order kept inside
          each group: those nothing rests first, then those resting on a rest
          MASC chose (an undated quota observation, or a rate limit inside the
          floor because it carried no usable Retry-After). *)
  ; held : ('a * float) list
      (** The candidates not to be called before the paired time, which the
          provider stated: the reset of the candidate's quota scope or the end
          of its own usable Retry-After, whichever is later. Declared order. *)
  }

val order_exact :
  now:float ->
  quota_scope_of:('a -> Runtime_quota_window.scope option) ->
  candidate_backpressure_of:('a -> Runtime_candidate_backpressure.candidate option) ->
  'a list -> 'a exact_order
(** What an Exact-output lane, an official-client one-shot or a media call
    walks at [now] (RFC-exact-lane-waits-for-a-stated-reset). A held
    candidate is not removed: it is in [held], and a read at a [now] past its
    time finds it in [walk] again. A candidate whose projections are missing
    is never held. Failed-attempt marks are not read. *)

type observation =
  | Answered
  | Rate_limited of { retry_after : float option }
  | Hard_quota of
      { source : Runtime_quota_window.refusal
            (** the typed constructor that refused: a 402 or the provider's
                hard quota *)
      ; resets_at : float option
      }
  | Credential_refused of { noted_at : float }
      (** The provider refused the credential itself. Shown to operators
          ({!Runtime_credential_refusal}); it orders nothing. *)

val observe :
  candidate:Runtime_candidate_backpressure.candidate option ->
  quota_scope:Runtime_quota_window.scope option -> observation -> unit
(** Record only facts about the actual dispatched frozen candidate/scope.
    [Answered] precedes syntax/domain validation, clears candidate evidence and
    undated quota, and preserves provider-stated reset windows. A rate limit
    never exhausts sibling credentials. [Answered] also clears a credential
    refusal noted on the scope. No ownerless failed-attempt is created.
    [None] means the attempt did not retain that identity, not a live lookup. *)

val observe_http_error :
  now:float -> candidate:Runtime_candidate_backpressure.candidate ->
  quota_scope:Runtime_quota_window.scope ->
  Llm_provider.Http_client.http_error -> unit
(** HTTP 402 / typed Hard_quota record account facts; 429 records candidate-only
    rate facts using the existing body/header parser. Other refusals, local
    admission, capacity and network failures create no ownerless Fleet mark. *)
