(** How one provider request differs from the previous request of the same
    keeper turn.

    A provider prompt cache reuses the longest common prefix of consecutive
    requests. This module digests the parts of that prefix that can change
    between two requests of one keeper turn -- the tool schemas and the
    messages -- and classifies how the current message list relates to the
    previous one. The system prompt is not digested: a keeper turn hands every
    request the same one. Messages and tool schemas are serialized the way
    {!Keeper_provider_input_snapshot} stores them, so there is one encoding of
    each; no digest leaves this module.

    The comparison is pure and linear in the two message counts.

    This is ongoing opt-in telemetry, not a temporary migration aid and not a
    runtime decision input. [Appended] and [Tail_removed] isolate cache misses
    with an unchanged shared message prefix; [Block_dropped] points to window
    or carried-range selection; [Rewritten_in_place] points to projection or
    demotion; [Diverged_at] gives the first still-unexplained coordinate; and
    [tools_changed] identifies the tool surface independently. These producers
    and provider behavior can change again, so the typed distinctions remain
    useful after the first measured diagnosis. *)

type request_digests
(** The digests of one request. *)

type digest_memo
(** The message digests already computed in one keeper turn, keyed by message
    value and by the exact floating-point bits in its raw JSON fields. This
    distinguishes [0.0] from [-0.0], whose provider encodings differ even
    though [Stdlib.compare] considers them equal. *)

val create_digest_memo : unit -> digest_memo
(** One memo per keeper turn. A message's encoding does not depend on the
    runtime, so the memo holds across the turn's runtime attempts. It is not
    safe to share between keepers or between turns that run at the same
    time. *)

type fresh_digest
(** One message digest computed after a memo snapshot. Its representation is
    private so only {!remember_digests} can merge it into the turn memo. *)

val snapshot_digest_memo : digest_memo -> digest_memo
(** Copy the turn memo on its owner fiber before submitting CPU work. The copy
    is private to that job, so a cancelled await cannot leave a worker reading
    shared mutable state while the next request advances. *)

val remember_digests : digest_memo -> fresh_digest list -> unit
(** Merge completed CPU work into the turn memo. Call only on the owner fiber,
    after the submitted job returned successfully. *)

val digest_request :
  seen:digest_memo ->
  tools:Agent_core.Tool.t list ->
  messages:Agent_core.Types.message list ->
  request_digests * fresh_digest list
(** Serializes and hashes every tool schema, and every message [seen] has not
    seen, in order; a message equal in value to one an earlier request of the
    turn carried takes that digest. The returned fresh entries are local CPU
    results: this function never mutates [seen] or the owner's turn memo.
    Repeated equal messages within one request share a job-local digest. *)

val message_count : request_digests -> int

(** What the turn knows about the request before the current one. *)
type previous_request =
  | No_request_yet
  | Request_not_digested
      (** A request was sent but its digests are unavailable, so a comparison
          against the request before it would describe the wrong pair. *)
  | Request_digested of request_digests

type message_change =
  | Appended of
      { kept : int
      ; added : int
      }
      (** The previous list is a prefix of the current list. [added = 0] is
          an identical list. *)
  | Tail_removed of
      { kept : int
      ; removed : int
      }
      (** The current list is a strict prefix of the previous list. *)
  | Block_dropped of
      { at : int
      ; dropped : int
      ; kept_after : int
      ; added : int
      }
      (** The lists share [at] leading messages, then
          [previous[at + dropped ..]] is a prefix of [current[at ..]], with
          [dropped > 0] and [kept_after > 0]. [at = 0] is a drop at the front;
          [at > 0] is a drop behind messages that stayed in place. The smallest
          such [dropped] is reported. *)
  | Rewritten_in_place of
      { first_index : int
      ; last_index : int
      ; rewritten : int
      ; previous_bytes : int
      ; current_bytes : int
      ; first_previous_role : Agent_core.Types.role
      ; first_current_role : Agent_core.Types.role
      ; added : int
      }
      (** No message moved: the previous list is not longer than the current
          one, [rewritten] positions between [first_index] and [last_index]
          hold a different message, and the message after [last_index] in the
          previous list is equal at the same position in the current one.
          [previous_bytes] and [current_bytes] sum the rewritten positions.
          [added] counts messages past the previous list's end. *)
  | Diverged_at of
      { index : int
      ; previous_role : Agent_core.Types.role
      ; previous_bytes : int
      ; current_role : Agent_core.Types.role
      ; current_bytes : int
      ; previous_count : int
      ; current_count : int
      }
      (** None of the above. [index] is the first position where the two
          lists differ, which is the number of leading messages the two
          requests share; both lists hold a message there. *)

type change =
  | First_request_of_turn
  | Previous_request_not_digested
  | Follows_previous_request of
      { messages : message_change
      ; tools_changed : bool
      }
      (** [tools_changed] compares the tool schema digests in order and does
          not depend on [messages]. *)

val compare_requests : previous:previous_request -> current:request_digests -> change
(** Checked in order: [Appended], [Tail_removed], [Block_dropped],
    [Rewritten_in_place], [Diverged_at]. A pair that fits more than one shape
    because of repeated messages gets the first. *)

val change_to_json : change -> Yojson.Safe.t
