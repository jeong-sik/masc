open Masc_tui_types

type press =
  | Arm of board_vote_target * bool
  | Send of board_vote_target * bool

let target_equal left right =
  match left, right with
  | Vote_post left, Vote_post right -> String.equal left right
  | Vote_comment left, Vote_comment right ->
      String.equal left.post_id right.post_id
      && String.equal left.comment_id right.comment_id
  | Vote_post _, Vote_comment _ | Vote_comment _, Vote_post _ -> false

let press ~armed ~target ~up =
  match armed with
  | Some (armed_target, armed_up)
    when target_equal armed_target target && Bool.equal armed_up up ->
      Send (target, up)
  | Some _ | None -> Arm (target, up)

let post_id = function
  | Vote_post post_id -> post_id
  | Vote_comment { post_id; _ } -> post_id

let describe = function
  | Vote_post post_id -> post_id
  | Vote_comment { comment_id; _ } -> "comment " ^ comment_id
