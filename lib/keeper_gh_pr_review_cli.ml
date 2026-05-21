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

let pr_review ~repo_slug ~pr_number ~body_file ~event_flag =
  [ "gh"; "pr"; "review"; string_of_int pr_number ]
  @ repo_args repo_slug
  @ [ "--body-file"; body_file; event_flag ]
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
