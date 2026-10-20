(** The Board's two-press vote over a typed target. The first press names a
    post or a comment and a direction; the same press again sends it. *)

type press =
  | Arm of Masc_tui_types.board_vote_target * bool
      (** Hold this target and direction for a second press. *)
  | Send of Masc_tui_types.board_vote_target * bool
      (** The press repeats the armed one: send it. *)

val target_equal :
  Masc_tui_types.board_vote_target -> Masc_tui_types.board_vote_target -> bool
(** Same kind and same ids. A post and a comment are never equal, whatever
    their ids spell. *)

val press :
  armed:(Masc_tui_types.board_vote_target * bool) option ->
  target:Masc_tui_types.board_vote_target -> up:bool -> press
(** [Send] only when [armed] holds this very target in this direction;
    anything else, including an arm on the other kind, re-arms. *)

val post_id : Masc_tui_types.board_vote_target -> string
(** The post the vote lands on or under, whose reading a completion
    refreshes. *)

val describe : Masc_tui_types.board_vote_target -> string
(** The target as the status line names it. *)
