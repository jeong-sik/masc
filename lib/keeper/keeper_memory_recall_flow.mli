(** The recall judgment flow
    (docs/rfc/RFC-keeper-recall-reaches-the-turn.md, sections 4.3 and 4.6):
    which requests are sent, in which order, and what a refused request comes
    to.

    Nothing here knows the TypeSafe client. Every request goes out through
    [evaluate], which the caller supplies. The caller wraps the client, writes
    its records around each call and maps the client's failure to
    {!attempt_failure}. This module catches no exception: a cancellation, or
    anything [evaluate] raises, leaves {!run} unchanged and builds no status.

    {!run} uses Eio fibers and has to run inside an Eio main loop. *)

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
    - the request of every piece and question (b) go out at the same time;
    - a piece that is refused for size is cut in two
      ({!Keeper_memory_recall_candidates.split} at half its line bytes) and
      the halves go out one after the other, front first, each by the same
      rule. A request holding one candidate cannot be cut. It waits for
      question (b): if the server took (b), the purpose fits and the candidate
      is [Too_large]. If (b) was refused for size too, the purpose alone is too
      big, so nothing else is sent and every candidate not yet decided is
      [Capacity]. If (b) failed some other way nothing is known about the
      purpose and the candidate is [Capacity], and the others go on. At most
      [2N - 1] question (a) requests go out for [N] candidates;
    - a piece that fails some other way leaves its candidates undecided:
      [Rate_limited], [Invalid_answer] for [Invalid_response], or
      [Provider_failed] for [Failed]. Nothing is retried;
    - once (a) and (b) are done, question (c) is asked for the carried
      candidates, one request for each request of (a) that was answered, holding
      the candidates that request carried. Those are some of the candidates
      the server took, without the purpose, so the request is not expected to
      be refused for size. It is never cut: a (c) request that fails, for any
      reason, leaves its candidates [Time_unjudged]. *)
