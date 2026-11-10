open Board_types

type t = {
  parent : posts_source_observation;
  policy : sub_boards_source_observation option;
}
(** Immutable read dependencies. [None] is only an unscoped canonical parent;
    an unregistered hearth still requires the observed policy-file absence. *)

val validate_parent : reader:Board_access.reader -> post_id:string ->
  audience:audience -> post -> (unit, board_error) result
(** Preserve the boundary reader, closed-thread and Direct audience rules. *)

val capture : store -> reader:Board_access.reader -> comment -> (t, board_error) result
(** Caller holds persistence then state. Validate canonical latest parent/policy rows,
    without publishing models or emitting parser diagnostics. The append must
    retain Posts -> Policy (when scoped) -> Comments locks through its effect. *)
