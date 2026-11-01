type cause = Board_error of Board_types.board_error | Raised of exn

type t =
  | Before_effect of cause
  | Unknown of cause
  | Committed of Board_types.post_creation * cause

let before_effect cause = Before_effect cause
let unknown cause = Unknown cause
let after_commit creation cause = Committed (creation, cause)

let with_cause failure cause =
  match failure with
  | Before_effect _ -> Before_effect cause
  | Unknown _ -> Unknown cause
  | Committed (creation, _) -> Committed (creation, cause)

let cause = function
  | Before_effect cause | Unknown cause | Committed (_, cause) -> cause

let effect_disposition = function
  | Before_effect _ -> Failure_effect.Proven_pre_effect
  | Unknown _ -> Failure_effect.Effect_outcome_unknown
  | Committed _ -> Failure_effect.Proven_post_effect

let committed = function
  | Before_effect _ | Unknown _ -> None
  | Committed (creation, _) -> Some creation

let to_string failure =
  match cause failure with
  | Board_error error -> Board_types.show_board_error error
  | Raised exn -> Printexc.to_string exn
