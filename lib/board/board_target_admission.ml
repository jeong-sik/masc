open Board_types
open Result.Syntax

type t = {
  post_id : Post_id.t;
  parent : posts_source_observation;
  comment : comments_source_observation option;
}

let unavailable () = Error (Io_error "Board data is unavailable.")

let comment_in_snapshot ~comment_id (snapshot : Fs_compat.private_jsonl_snapshot) =
  let rec rows found = function
    | [] -> (match found with
        | Some comment -> Ok comment
        | None -> Error (Comment_not_found comment_id))
    | text :: remaining when String.equal (String.trim text) "" -> rows found remaining
    | text :: remaining ->
      match Yojson.Safe.from_string text with
      | json ->
        let decoded = Board_content_json.comment_of_yojson json in
        (match decoded.value with
         | None -> unavailable ()
         | Some comment ->
           let found = if String.equal comment_id (Comment_id.to_string comment.id)
             then Some comment else found in
           rows found remaining)
      | exception Yojson.Json_error _ -> unavailable () in
  rows None (String.split_on_char '\n' snapshot.bytes)

let capture store ~reader ~target_type ~target_id =
  let* target_id = match target_type with
    | Reaction_post -> Result.map Post_id.to_string (Post_id.of_string target_id)
    | Reaction_comment -> Result.map Comment_id.to_string (Comment_id.of_string target_id) in
  let* parent = match store.posts_source with
    | Posts_readable { observation; _ } when
        String.equal observation.source_path (Board_paths.persist_path store) -> Ok observation
    | Posts_readable _ | Posts_unobserved | Posts_refused _ | Posts_unsettled _ -> unavailable () in
  let* comment = match target_type with
    | Reaction_post -> Ok None
    | Reaction_comment ->
      (match store.comments_source with
       | Comments_readable { observation; _ } when
           String.equal observation.source_path (Board_paths.comments_path store) -> Ok (Some observation)
       | Comments_readable _ | Comments_unobserved | Comments_publishing _
       | Comments_refused _ | Comments_unsettled _ | Comments_recovered _ -> unavailable ()) in
  let* post_id = match target_type, comment with
    | Reaction_post, None -> Post_id.of_string target_id
    | Reaction_comment, Some observation ->
      let* canonical = comment_in_snapshot ~comment_id:target_id observation.snapshot in
      (match Hashtbl.find_opt store.comments target_id with
       | None -> Error (Comment_not_found target_id)
       | Some cached when cached.post_id = canonical.post_id && cached.author = canonical.author
           && cached.audience = canonical.audience -> Ok canonical.post_id
       | Some _ -> unavailable ())
    | Reaction_post, Some _ | Reaction_comment, None -> unavailable () in
  let key = Post_id.to_string post_id in
  let missing () = Error (match target_type with
    | Reaction_post -> Post_not_found target_id
    | Reaction_comment -> Comment_not_found target_id) in
  let* post = match Board_posts_rows.latest ~post_id:key parent.snapshot with
    | Error (Post_not_found _) -> missing ()
    | Ok _ | Error (Invalid_id _ | Comment_not_found _ | Io_error _
        | Validation_error _ | Already_voted _ | Already_exists _ | Unauthorized _
        | Recipient_lookup_failed _) as result -> result in
  if not (Board_access.can_read ~reader post) then missing ()
  else
    (* Counters and updated_at can be legitimately dirty. Authority/routing
       fields must agree before a fresh source authorizes a cached model. *)
    match Hashtbl.find_opt store.posts key with
    | None -> missing ()
    | Some cached when cached.author = post.author && cached.visibility = post.visibility
        && cached.audience = post.audience && cached.closed = post.closed
        && cached.hearth = post.hearth -> Ok { post_id; parent; comment }
    | Some _ -> unavailable ()

let revalidate store admission =
  try
    let* () = Board_workspace_binding.revalidate store.workspace_binding
        admission.parent.workspace_observation in
    match admission.comment with
    | None -> Ok ()
    | Some comment -> Board_workspace_binding.revalidate store.workspace_binding
        comment.workspace_observation
  with exception_ -> Error (Board_workspace_binding.Raised {
    exception_; backtrace = Printexc.get_raw_backtrace () })

type dependency = Parent_posts | Parent_comments
type refusal = {
  dependency : dependency;
  failure : Fs_compat.private_jsonl_guard_failure;
  cleanup_failures : Fs_compat.private_jsonl_guard_failure list;
}
type 'a guarded =
  | Refused of refusal
  | Executed of { value : 'a; cleanup_failures : Fs_compat.private_jsonl_guard_failure list }

let with_guard io path ~expected ~f = match io with
  | None -> Fs_compat.with_private_jsonl_snapshot_guard_result path ~expected ~f
  | Some io -> Fs_compat.with_private_jsonl_snapshot_guard_with_io_for_testing ~io path ~expected ~f

let guard admission ~posts_io ~comments_io ~f =
  let parent = admission.parent in
  match admission.comment with
  | None ->
    (match with_guard posts_io parent.source_path ~expected:parent.snapshot ~f with
     | Fs_compat.Guard_refused failure -> Refused {
         dependency = Parent_posts; failure; cleanup_failures = [] }
     | Fs_compat.Guard_executed { value; cleanup_failures } -> Executed { value; cleanup_failures })
  | Some comment ->
    match with_guard posts_io parent.source_path ~expected:parent.snapshot ~f:(fun () ->
      with_guard comments_io comment.source_path ~expected:comment.snapshot ~f) with
    | Fs_compat.Guard_refused failure -> Refused {
        dependency = Parent_posts; failure; cleanup_failures = [] }
    | Fs_compat.Guard_executed { value = Fs_compat.Guard_refused failure; cleanup_failures } ->
      Refused { dependency = Parent_comments; failure; cleanup_failures }
    | Fs_compat.Guard_executed {
        value = Fs_compat.Guard_executed { value; cleanup_failures = comment_cleanup };
        cleanup_failures = parent_cleanup } ->
      Executed { value; cleanup_failures = comment_cleanup @ parent_cleanup }

let observe_refusal store admission refusal = match refusal.dependency with
  | Parent_posts -> Board_posts_source.observe_guard_refusal store admission.parent refusal.failure
  | Parent_comments ->
    match admission.comment with
    | None -> ()
    | Some comment -> Board_comments_source.observe_guard_refusal store comment refusal.failure
