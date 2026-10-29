(** The recall judgment flow
    (docs/rfc/RFC-keeper-recall-reaches-the-turn.md, sections 4.3 and 4.6):
    which requests are sent, in which order, and what a refused request comes
    to.

    Nothing here knows the TypeSafe client. Every request goes out through
    [evaluate], which the caller supplies. The caller wraps the client, writes
    its records around each call and maps the client's failure to
    {!attempt_failure}. This module catches no exception: a cancellation, or
    anything [evaluate] raises, comes out of {!run} and builds no status. When
    requests fail with different exceptions at the same time, Eio raises them
    together as [Eio.Exn.Multiple]. A [Cancelled] that [evaluate] raises for
    question (b) with no cancelled context behind it comes out wrapped in one
    more [Cancelled].

    {!run} uses Eio fibers and has to run inside an Eio main loop. [evaluate]
    is called from several fibers at the same time and has to allow that. *)

type attempt_failure =
  | Capacity_refused
      (** Every destination refused the request for its size. *)
  | Rate_limited
      (** Every destination answered HTTP 429. *)
  | Invalid_response
      (** Every destination took the request and returned a response that
          does not decode. *)
  | Failed
      (** Any other failure, a timeout among them. *)
  | Not_recorded
      (** The caller could not save the record of the request, so nothing was
          sent, or could not save the record of the response, so the response
          is not used. *)

type evaluate =
  Keeper_memory_recall_jev_codec.request ->
  (Typesafeai_types.eval_response, attempt_failure) result

type judged =
  { status : Keeper_memory_recall_judgment.status
  ; results : Keeper_memory_recall_judgment.candidate_result list
        (** One per candidate, in candidate order. *)
  ; turn : Keeper_memory_recall_judgment.turn_answer
        (** What question (b) came to. A refused or failed request is
            [Turn_question_failed]. *)
  ; marks : (string * Keeper_memory_recall_judgment.time_mark) list
        (** Question (c) for the carried candidates, in candidate order: one
            entry per carried candidate, and none for the others. *)
  }

val not_recorded : judged -> judged
(** The judgment to use when the record of its outcome could not be saved.
    Nothing of the original is kept: every candidate is undecided with
    [Not_recorded], question (b) counts as failed and there are no marks, so
    the status is [unavailable] with that reason. *)

val run :
  evaluate:evaluate ->
  purpose:Yojson.Safe.t ->
  ?piece_bytes:int ->
  Keeper_memory_recall_candidates.t list ->
  (judged option, Keeper_memory_recall_jev_codec.build_error) result
(** [Ok None] for no candidates: nothing is sent. [Error] when a request cannot
    be built, before anything is sent: two candidates share an id (in one piece
    or in two), or an option set is invalid.

    Otherwise:
    - the candidates are cut into pieces of at most [piece_bytes] of line
      bytes (default {!Keeper_memory_recall_candidates.state_bytes_per_piece});
    - the request of every piece and question (b) go out at the same time. An
      exception on either side cancels the other;
    - a piece that is refused for size is cut again
      ({!Keeper_memory_recall_candidates.split} with half its line bytes as the
      limit). That gives two pieces or more, because one big candidate can sit
      alone. The new pieces go out one after the other, front first, each by
      the same rule. A request holding one candidate cannot be cut. It waits for
      question (b): if the server took (b), the purpose fits and the candidate
      is [Too_large]. If (b) was refused for size too, the purpose alone is too
      big, so nothing else is sent and every candidate not yet decided is
      [Capacity]. If (b) failed some other way nothing is known about the
      purpose and the candidate is [Capacity], and the others go on. At most
      [2N - 1] question (a) requests go out for [N] candidates;
    - a piece that fails some other way leaves its candidates undecided:
      [Rate_limited], [Invalid_answer] for [Invalid_response],
      [Provider_failed] for [Failed], or [Not_recorded]. Nothing is retried;
    - once (a) and (b) are done, question (c) is asked for the carried
      candidates, one request for each request of (a) that was answered, holding
      the candidates that request carried. Those are some of the candidates
      the server took, without the purpose, so the request is not expected to
      be refused for size. That is not certain: the question text of (c) is
      longer than that of (a) for each candidate (RFC section 4.8 has the
      measure). A (c) request is never cut.
      When it fails, for any reason, its candidates are [Time_unjudged].
      The (c) requests go out at the same time. *)
