open Board_types

type t =
  | First_vote of vote_direction
  | Flip of vote_direction

type decision =
  | Already_cast
  | Cast of t

let decide ~previous ~direction =
  match previous, direction with
  | None, (Up | Down) -> Cast (First_vote direction)
  | Some Up, Up | Some Down, Down -> Already_cast
  | Some Up, Down | Some Down, Up -> Cast (Flip direction)

let apply_counts transition ~votes_up ~votes_down =
  match transition with
  | First_vote Up -> votes_up + 1, votes_down
  | First_vote Down -> votes_up, votes_down + 1
  | Flip Up -> votes_up + 1, max 0 (votes_down - 1)
  | Flip Down -> max 0 (votes_up - 1), votes_down + 1
