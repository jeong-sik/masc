(** How one provider request differs from the previous request of the same
    keeper turn.

    A provider prompt cache reuses the longest common prefix of consecutive
    requests. This module digests the parts that prefix is made of -- the
    system prompt, the tool schemas, and the provider-bound messages -- and
    classifies how the current message list relates to the previous one. Every
    digest is the SHA-256 of the payload {!Keeper_provider_input_snapshot}
    stores for the same value, so a digest here names a provider-input
    snapshot artifact.

    The comparison is pure and linear in the two message counts. *)

type request_digests
(** The digests of one request. *)

val digest_request :
  system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  messages:Agent_core.Types.message list ->
  request_digests
(** Serializes and hashes the system prompt, every tool schema, and every
    message, in order. [system_prompt] is expected in the form the
    provider-input snapshot receives it. Pure and CPU-bound; safe on any
    domain. *)

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
      ; system_prompt_changed : bool
      ; tools_changed : bool
      }
      (** [system_prompt_changed] and [tools_changed] are computed from their
          own digests and do not depend on [messages]. *)

val compare_requests : previous:previous_request -> current:request_digests -> change
(** Checked in order: [Appended], [Tail_removed], [Block_dropped],
    [Rewritten_in_place], [Diverged_at]. A pair that fits more than one shape because of repeated
    messages gets the first. *)

val change_to_json : change -> Yojson.Safe.t
