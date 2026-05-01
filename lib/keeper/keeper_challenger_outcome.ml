(** Keeper_challenger_outcome — structured outcome variants for the challenger round.

    String matching on outcome descriptions is forbidden (memory
    [no-string-matching-classification]).  All decisions must be encoded
    as variants so downstream pattern-matches are exhaustive and type-checked.

    @since A1 Dialectical Verification *)

(** Reason payload carried by a [Veto] outcome.  All fields are required;
    the challenger must supply a concrete [rule] token and a human-readable
    [detail] describing what diverged.  [challenger_cascade] records which
    cascade the challenger ran under so veto provenance is auditable. *)
type veto_reason =
  { rule : string
        (** Short rule token, e.g. "destructive_action" or "scope_violation". *)
  ; detail : string
        (** Human-readable description of the divergence found by the challenger. *)
  ; challenger_cascade : string
        (** Cascade name used by the challenger that produced this veto. *)
  }

(** Challenger evaluation outcome.

    - [Accept]  — challenger found no objection; the original turn result
                  proceeds unmodified through [apply_post_turn_lifecycle].
    - [No_challenger] — challenger evaluation was skipped (env flag off,
                  eligibility gate failed, or cascade not configured).
    - [Veto r]  — challenger raised a structured objection.  The caller
                  is responsible for routing to [handle_challenger_veto]. *)
type t =
  | Accept
  | No_challenger
  | Veto of veto_reason
