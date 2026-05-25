(** Typed argv builders for the keeper PR review GitHub CLI surface.

    This module owns the [gh] command shape for keeper_pr_review. Callers choose
    the execution target; this module only returns argv. *)

let quote_argv argv = String.concat " " (List.map Filename.quote argv)
let repo_args repo_slug = [ "-R"; repo_slug ]

let truncate_max ~max_bytes s =
  if String.length s <= max_bytes then s else String.sub s 0 max_bytes
;;

let repo_view_name_with_owner repo_slug =
  [ "gh"; "repo"; "view"; repo_slug; "--json"; "nameWithOwner" ]
;;

let pr_view_json ~repo_slug ~pr_number ~json_fields =
  [ "gh"; "pr"; "view"; string_of_int pr_number ]
  @ repo_args repo_slug
  @ [ "--json"; json_fields ]
;;

let pr_diff ~repo_slug ~pr_number =
  [ "gh"; "pr"; "diff"; string_of_int pr_number ] @ repo_args repo_slug
;;

let gh_review_event_of_flag = function
  | "--comment" -> "COMMENT"
  | "--approve" -> "APPROVE"
  | "--request-changes" -> "REQUEST_CHANGES"
  | other -> other

let pr_review ~repo_slug ~pr_number ~body_file ~event_flag =
  let endpoint =
    Printf.sprintf "repos/%s/pulls/%d/reviews" repo_slug pr_number
  in
  let event = gh_review_event_of_flag event_flag in
  [ "gh"; "api"; endpoint; "-F"; "body=@" ^ body_file; "-f"
  ; "event=" ^ event
  ]
;;

let pr_list_open ~repo_slug ~limit =
  [ "gh"; "pr"; "list"; "-R"; repo_slug; "--state"; "open"; "--limit"
  ; string_of_int limit
  ; "--json"; "number,title"
  ]
;;

let pr_comment_reply ~owner_repo ~pr_number ~comment_id ~body_file =
  let endpoint =
    Printf.sprintf
      "repos/%s/pulls/%d/comments/%d/replies"
      owner_repo
      pr_number
      comment_id
  in
  [ "gh"; "api"; endpoint; "-F"; "body=@" ^ body_file ]
;;
