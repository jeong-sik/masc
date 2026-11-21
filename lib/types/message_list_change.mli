(** How the message list of one provider request relates to the message list
    of an earlier request. [Keeper_projection_change] classifies two requests
    of one Keeper turn, or the last requests of two turns, into this type.

    The type and its JSON live here, beside {!Turn_record}, so the server and
    the TUI read one definition. *)

type t =
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
      ; first_previous_role : Llm_provider.Types.role
      ; first_current_role : Llm_provider.Types.role
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
      ; previous_role : Llm_provider.Types.role
      ; previous_bytes : int
      ; current_role : Llm_provider.Types.role
      ; current_bytes : int
      ; previous_count : int
      ; current_count : int
      }
      (** None of the above. [index] is the first position where the two
          lists differ, which is the number of leading messages the two
          requests share; both lists hold a message there. *)

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
(** Reads a {!to_json} object back. An unknown kind, a missing or negative
    count, or an unknown role is an error. *)
