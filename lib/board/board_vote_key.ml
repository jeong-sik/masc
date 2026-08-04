open Board_types

type target_kind =
  | Post
  | Comment

type t =
  { target_kind : target_kind
  ; target_id : string
  ; voter : Agent_id.t
  }

let post ~post_id ~voter =
  { target_kind = Post; target_id = Post_id.to_string post_id; voter }
;;

let comment ~comment_id ~voter =
  { target_kind = Comment; target_id = Comment_id.to_string comment_id; voter }
;;

let target_kind vote = vote.target_kind
let target_id vote = vote.target_id
let voter vote = vote.voter

let to_string vote =
  let kind =
    match vote.target_kind with
    | Post -> "post"
    | Comment -> "comment"
  in
  String.concat ":" [ kind; vote.target_id; Agent_id.to_string vote.voter ]
;;

let of_string raw =
  match String.index_opt raw ':' with
  | None -> None
  | Some first_separator ->
    let kind_raw = String.sub raw 0 first_separator in
    let remainder =
      String.sub
        raw
        (first_separator + 1)
        (String.length raw - first_separator - 1)
    in
    (match String.index_opt remainder ':' with
     | None -> None
     | Some second_separator ->
       let target_id_raw = String.sub remainder 0 second_separator in
       let voter_raw =
         String.sub
           remainder
           (second_separator + 1)
           (String.length remainder - second_separator - 1)
       in
       let target =
         match kind_raw with
         | "post" ->
           (match Post_id.of_string target_id_raw with
            | Ok post_id
              when String.equal target_id_raw (Post_id.to_string post_id) ->
              Some (Post, Post_id.to_string post_id)
            | Ok _ | Error _ -> None)
         | "comment" ->
           (match Comment_id.of_string target_id_raw with
            | Ok comment_id
              when String.equal target_id_raw (Comment_id.to_string comment_id) ->
              Some (Comment, Comment_id.to_string comment_id)
            | Ok _ | Error _ -> None)
         | _ -> None
       in
       (match target, Agent_id.of_string voter_raw with
        | Some (target_kind, target_id), Ok voter
          when String.equal voter_raw (Agent_id.to_string voter) ->
          Some { target_kind; target_id; voter }
        | Some _, Ok _ | Some _, Error _ | None, _ -> None))
;;
