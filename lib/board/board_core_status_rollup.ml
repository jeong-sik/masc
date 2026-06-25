(** Status-rollup classification + target search, extracted from
    [board_core.ml] (godfile decomp).

    Encapsulates the policy that decides when a new automation post
    should "roll up" into an existing recent post for the same task,
    rather than creating a fresh entry. The rollup target search
    walks [store.posts] to find a recent same-author, same-hearth,
    same-task automation post whose body matches the "status-only"
    classifier and does NOT match the "proof-or-handoff" terms.

    Public surface:
    - [status_rollup_window_sec] = 6h (rollup eligibility window)
    - [max_status_rollup_body_length] = 600 (substantive-content cap)
    - [status_rollup_task_id] — extract task id from meta JSON
      ("task_id"/"current_task_id"/"claimed_task_id"/"task" keys) or
      fallback to body/title "task-<chars>" marker scan
    - [is_status_rollup_candidate] — gate eligible only on
      [Automation_post]; [Human_post] and [System_post] never roll up
    - [find_status_rollup_target_unlocked] — walks [store.posts] for
      the most recently-updated eligible rollup target

    Type identity preserved via `include Board_types` — the [post]
    record, [post_kind] variant ([Human_post|System_post|
    Automation_post]), [Agent_id] module, and other board types all
    flow through unchanged. *)

include Board_types

let status_rollup_window_sec = 6. *. 60. *. 60.
let max_status_rollup_body_length = 600

let is_term_token_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
  | _ -> false
;;

let contains_term_ci text term =
  let text_len = String.length text in
  let term_len = String.length term in
  if term_len = 0 || term_len > text_len
  then false
  else (
    let starts_with_token = is_term_token_char term.[0] in
    let ends_with_token = is_term_token_char term.[term_len - 1] in
    let left_boundary idx =
      (not starts_with_token) || idx = 0 || not (is_term_token_char text.[idx - 1])
    in
    let right_boundary idx =
      let stop = idx + term_len in
      (not ends_with_token) || stop = text_len || not (is_term_token_char text.[stop])
    in
    let rec match_at idx term_idx =
      if term_idx = term_len
      then true
      else (
        let text_char = Char.lowercase_ascii text.[idx + term_idx] in
        let term_char = Char.lowercase_ascii term.[term_idx] in
        Char.equal text_char term_char && match_at idx (term_idx + 1))
    in
    let last = text_len - term_len in
    let rec loop idx =
      idx <= last
      && ((left_boundary idx && right_boundary idx && match_at idx 0)
          || loop (idx + 1))
    in
    loop 0)
;;

let contains_any_term text terms = List.exists (contains_term_ci text) terms
;;

let is_task_id_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
  | _ -> false
;;

let task_id_from_text text =
  let marker = "task-" in
  let marker_len = String.length marker in
  let len = String.length text in
  let lower = String.lowercase_ascii text in
  let rec loop idx =
    if idx + marker_len > len
    then None
    else if String.equal (String.sub lower idx marker_len) marker
    then (
      let stop = ref (idx + marker_len) in
      while !stop < len && is_task_id_char text.[!stop] do
        Stdlib.incr stop
      done;
      if !stop > idx + marker_len
      then Some (String.sub lower idx (!stop - idx))
      else loop (idx + 1))
    else loop (idx + 1)
  in
  loop 0
;;

let status_rollup_task_id ~title ~body ~meta_json =
  match
    List.find_map
      (fun key -> Option.bind meta_json (Json_util.assoc_string_opt key))
      [ "task_id"; "current_task_id"; "claimed_task_id"; "task" ]
  with
  | Some task_id -> Some (String.lowercase_ascii task_id)
  | None ->
    (match task_id_from_text body with
     | Some _ as task_id -> task_id
     | None -> task_id_from_text title)
;;

let status_only_terms =
  [ "claimed"
  ; "claiming"
  ; "worktree ready"
  ; "worktree exists"
  ; "investigating"
  ; "checking"
  ; "scanning"
  ; "starting"
  ; "started"
  ; "beginning"
  ; "in progress"
  ; "progress update"
  ; "continuing"
  ; "classifying"
  ; "triaging"
  ; "reviewing"
  ; "preparing"
  ; "backlog"
  ]
;;

let proof_or_handoff_terms =
  [ "blocked"
  ; "blocker"
  ; "cannot"
  ; "stuck"
  ; "error"
  ; "exception"
  ; "failed"
  ; "failure"
  ; "timeout"
  ; "crash"
  ; "root cause"
  ; "evidence"
  ; "verified"
  ; "verification"
  ; "tests passed"
  ; "test passed"
  ; "tests failed"
  ; "test failed"
  ; "gh pr"
  ; "pr #"
  ; "pull request"
  ; "commit"
  ; "changed files"
  ; "repro"
  ; "reproduction"
  ; "handoff"
  ; "ready for review"
  ; "ready for pr"
  ; "done"
  ; "completed"
  ; "fixed"
  ; "merged"
  ]
;;

let is_status_rollup_candidate ~post_kind ~title ~body ~meta_json =
  match post_kind with
  | Human_post | System_post -> false
  | Automation_post ->
    String.length body <= max_status_rollup_body_length
    && Option.is_some (status_rollup_task_id ~title ~body ~meta_json)
    && contains_any_term body status_only_terms
    && not (contains_any_term body proof_or_handoff_terms)
;;

let find_status_rollup_target_unlocked
      store
      ~author_id
      ~hearth
      ~visibility
      ~task_id
      ~now
  =
  Hashtbl.fold
    (fun _ (post : post) acc ->
       let same_author =
         String.equal (Agent_id.to_string post.author) (Agent_id.to_string author_id)
       in
       let same_hearth = Option.equal String.equal post.hearth hearth in
       let same_task =
         match
           status_rollup_task_id
             ~title:post.title
             ~body:post.body
             ~meta_json:post.meta_json
         with
         | Some existing_task_id -> String.equal existing_task_id task_id
         | None -> false
       in
       let recent =
         Stdlib.Float.compare (now -. post.created_at) status_rollup_window_sec <= 0
       in
       if
         same_author
         && same_hearth
         && post.visibility = visibility
         && same_task
         && recent
         && is_status_rollup_candidate
              ~post_kind:post.post_kind
              ~title:post.title
              ~body:post.body
              ~meta_json:post.meta_json
       then (
         match acc with
         | Some current when current.updated_at >= post.updated_at -> acc
         | _ -> Some post)
       else acc)
    store.posts
    None
;;
