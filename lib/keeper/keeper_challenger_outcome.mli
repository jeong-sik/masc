(** Keeper_challenger_outcome — structured outcome variants for the challenger round.

    String matching on outcome descriptions is forbidden (memory
    [no-string-matching-classification]).  All decisions must be encoded
    as variants so downstream pattern-matches are exhaustive and type-checked.

    @since A1 Dialectical Verification *)

type veto_reason =
  { rule : string
  ; detail : string
  ; challenger_cascade : string
  }
(** Reason payload carried by a [Veto] outcome. *)

type t =
  | Accept
      (** Challenger found no objection; original turn result proceeds. *)
  | No_challenger
      (** Challenger evaluation was skipped (env flag off, eligibility gate
          failed, or cascade not configured). *)
  | Veto of veto_reason
      (** Challenger raised a structured objection. *)
