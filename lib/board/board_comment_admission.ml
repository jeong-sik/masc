open Board_types
open Result.Syntax

type t = {
  parent : posts_source_observation;
  policy : sub_boards_source_observation option;
}

let unavailable () = Error (Io_error "Board data is unavailable.")

let validate_parent ~reader ~post_id ~audience (post : post) =
  if not (Board_access.can_read ~reader post) then Error (Post_not_found post_id)
  else match post.closed with
  | Some closed ->
    let message = match closed.successor_id with
      | Some sid -> Printf.sprintf "Post %s is closed; see successor %s"
          post_id (Post_id.to_string sid)
      | None -> Printf.sprintf "Post %s is closed" post_id in
    Error (Validation_error message)
  | None ->
    match post.visibility, audience with
    | (Public | Unlisted | Internal), (Thread_participants | Broadcast | Discoverable | Targets _) -> Ok ()
    | Direct, Thread_participants -> Ok ()
    | Direct, (Broadcast | Discoverable) ->
      Error (Validation_error "Direct Board comments cannot broadcast")
    | Direct, Targets targets ->
      let readers = post.author :: (match post.audience with
        | Some (Targets targets) -> targets
        | Some (Broadcast | Thread_participants | Discoverable) | None -> []) in
      if List.for_all (fun target -> List.exists (fun reader ->
          String.equal (Agent_id.to_string target) (Agent_id.to_string reader)) readers) targets
      then Ok ()
      else Error (Validation_error "Direct Board comments can address only the parent post's readers")

let parent_in_snapshot ~post_id (snapshot : Fs_compat.private_jsonl_snapshot) =
  let rec rows line parent = function
    | [] -> (match parent with Some post -> Ok post | None -> Error (Post_not_found post_id))
    | text :: remaining ->
      match Board_posts_rows.decode ~line text with
      | Board_posts_rows.Blank -> rows (line + 1) parent remaining
      | Board_posts_rows.Rejected _ -> unavailable ()
      | Board_posts_rows.Accepted { post; _ } ->
        let parent = if String.equal post_id (Post_id.to_string post.id) then Some post else parent in
        rows (line + 1) parent remaining in
  rows 1 None (String.split_on_char '\n' snapshot.bytes)

let capture store ~reader (comment : comment) =
  let* parent = match store.posts_source with
    | Posts_readable { observation; _ } when
        String.equal observation.source_path (Board_paths.persist_path store) -> Ok observation
    | Posts_readable _ | Posts_unobserved | Posts_refused _ | Posts_unsettled _ -> unavailable () in
  let post_id = Post_id.to_string comment.post_id in
  let* post = parent_in_snapshot ~post_id parent.snapshot in
  let* audience = match comment.audience with
    | Some audience -> Ok audience
    | None -> Error (Validation_error "Comment audience is unavailable.") in
  let* () = validate_parent ~reader ~post_id ~audience post in
  (* A public source-only settlement can leave an older model behind. That
     model drives routing and commit, so a fresh source cannot authorize its
     old access/hearth fields. Normal dirty reply counters may still differ. *)
  let* () = match Hashtbl.find_opt store.posts post_id with
    | None -> Error (Post_not_found post_id)
    | Some cached ->
      if cached.author = post.author && cached.visibility = post.visibility
         && cached.audience = post.audience && cached.closed = post.closed
         && cached.hearth = post.hearth then Ok () else unavailable () in
  let* policy = Board_policy_admission.capture store
      ~author_id:comment.author ~hearth:post.hearth in
  Ok { parent; policy }
