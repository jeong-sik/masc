(** Shared quota/rate/failure ordering over the actual candidate observation.
    Ordering preserves every candidate and declared order within each class.
    It confers no dispatch or mutation authority. *)

type walk_start =
  | Fresh_walk_by of Runtime_candidate_backpressure.recorder
  | Every_mark_demotes

type policy =
  | Keeper_walk of walk_start
      (** Rate observations stand until an answer or their provider hint ends.
          Other Keepers' failures demote, while a fresh recorder retries its
          own marks. A deferred/one-shot walk demotes every failure. *)
  | Rate_rest_only of { rest_sec : retry_after:float option -> float }
      (** Exact/media calls read quota and the existing provider-path rest,
          ignoring Fleet failed-attempt marks. The caller supplies its existing
          rest policy; this query invents no TTL or recorder. *)

val order :
  now:float -> policy:policy ->
  quota_scope_of:('a -> Runtime_quota_window.scope option) ->
  candidate_backpressure_of:('a -> Runtime_candidate_backpressure.candidate option) ->
  'a list -> 'a list
(** Resolve both projections from the same frozen row. Missing projections
    contribute no evidence and never remove an unresolved declared identity. *)

type observation =
  | Answered
  | Rate_limited of { retry_after : float option }
  | Hard_quota of { resets_at : float option }

val observe :
  candidate:Runtime_candidate_backpressure.candidate option ->
  quota_scope:Runtime_quota_window.scope option -> observation -> unit
(** Record only facts about the actual dispatched frozen candidate/scope.
    [Answered] precedes syntax/domain validation, clears candidate evidence and
    undated quota, and preserves provider-stated reset windows. A rate limit
    never exhausts sibling credentials. No ownerless failed-attempt is created.
    [None] means the attempt did not retain that identity, not a live lookup. *)

val observe_http_error :
  now:float -> candidate:Runtime_candidate_backpressure.candidate ->
  quota_scope:Runtime_quota_window.scope ->
  Llm_provider.Http_client.http_error -> unit
(** HTTP 402 / typed Hard_quota record account facts; 429 records candidate-only
    rate facts using the existing body/header parser. Other refusals, local
    admission, capacity and network failures create no ownerless Fleet mark. *)
