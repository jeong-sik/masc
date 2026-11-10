open Board_types
open Board_core_persist
open Result.Syntax

module Source = Board_deletion_source
module Batch = Board_snapshot_batch
module String_set = Set_util.StringSet

type deletion_authorization =
  | Operator_deletion
  | Author_deletion of { reader : Board_access.reader; author : Agent_id.t }
  | Cleanup_deletion of Board_access.reader

type deletion_outcome =
  | Durable_deletion
  | Deletion_decision_pending of string
  | Deletion_persistence_pending of string

let pending_detail = "Board deletion recovery is pending. Do not repeat the deletion."

let require_sources store =
  let* () = require_posts_source_readable store in
  let* () = require_comments_source_readable store in
  let* () = Board_votes_source.require_readable store in
  Board_reactions_source.require_readable store

let reactions_jsonl store =
  let buffer = Buffer.create 4096 in
  Hashtbl.iter (fun _ (reaction : reaction) ->
    Buffer.add_string buffer (Yojson.Safe.to_string (Board_core_json.reaction_to_yojson reaction));
    Buffer.add_char buffer '\n') store.reactions;
  Buffer.contents buffer

let capture store selection =
  let batch = Batch.capture selection
    ~posts:(fun () -> capture_posts_snapshot store)
    ~comments:(fun () -> capture_comments_snapshot store)
    ~votes:(fun () -> Board_voting.vote_log_jsonl store)
    ~reactions:(fun () -> reactions_jsonl store) in
  Hashtbl.clear store.dirty_post_ids;
  Hashtbl.clear store.dirty_comment_ids;
  store.dirty_posts <- false;
  store.dirty_comments <- false;
  store.last_flush <- Time_compat.now ();
  batch

let write_snapshot store = function
  | Batch.Posts_payload snapshot -> finish_posts_write (save_posts_snapshot store snapshot)
  | Batch.Comments_payload snapshot -> save_comments_snapshot store snapshot
  | Batch.Votes_payload bytes ->
    let* () = Board_votes_source.require_readable store in
    Board_voting.save_vote_log_jsonl store bytes
  | Batch.Reactions_payload bytes ->
    let* () = Board_reactions_source.require_readable store in
    save_reactions_jsonl_result store bytes

let remark store = function
  | Batch.Retry_posts ->
    store.dirty_posts <- true;
    Hashtbl.iter (fun id _ -> Hashtbl.replace store.dirty_post_ids id ()) store.posts
  | Batch.Retry_comments ->
    store.dirty_comments <- true;
    Hashtbl.iter (fun id _ -> Hashtbl.replace store.dirty_comment_ids id ()) store.comments

let authorize ~authorization (post : post) = match authorization with
  | Operator_deletion -> Ok ()
  | Author_deletion { reader; author } ->
    if not (Board_access.can_read ~reader post) then Error (Post_not_found (Post_id.to_string post.id))
    else if String.equal (Agent_id.to_string author) (Agent_id.to_string post.author) then Ok ()
    else Error (Unauthorized "Only the current author can delete this post.")
  | Cleanup_deletion reader ->
    if Board_access.can_read ~reader post then Ok ()
    else Error (Post_not_found (Post_id.to_string post.id))

let parent_in_snapshot ~post_id (snapshot : Fs_compat.private_jsonl_snapshot) =
  (* Settlement can prove a source write without publishing its model. Read
     the canonical latest parent from the exact bytes we will guard, rather
     than borrowing a fresh observation to authorize the old model. *)
  let rec rows line parent = function
    | [] -> (match parent with Some post -> Ok post | None -> Error (Post_not_found post_id))
    | text :: remaining ->
      match Board_posts_rows.decode ~line text with
      | Board_posts_rows.Blank -> rows (line + 1) parent remaining
      | Board_posts_rows.Rejected _ -> Error (Io_error "Board data is unavailable.")
      | Board_posts_rows.Accepted { post; _ } ->
        let parent = if String.equal post_id (Post_id.to_string post.id) then Some post else parent in
        rows (line + 1) parent remaining in
  rows 1 None (String.split_on_char '\n' snapshot.bytes)

let stage store ~authorization pid =
  let post_id = Post_id.to_string pid in
  match Hashtbl.find_opt store.posts post_id with
  | None -> Error (Post_not_found post_id)
  | Some post ->
    let* () = authorize ~authorization post in
    let* observation = match store.posts_source with
      | Posts_readable { observation; _ } -> Ok observation
      | Posts_unobserved | Posts_refused _ | Posts_unsettled _ ->
        Error (Io_error "Board data is unavailable.") in
    let* source_parent = parent_in_snapshot ~post_id observation.snapshot in
    let* () = authorize ~authorization source_parent in
    let deleted_comments = Hashtbl.fold (fun _ (comment : comment) ids ->
      if String.equal (Post_id.to_string comment.post_id) post_id then comment.id :: ids else ids)
      store.comments []
      |> List.sort (fun left right -> String.compare (Comment_id.to_string left) (Comment_id.to_string right)) in
    Ok ({ decision_id = Deletion_id.generate (); deleted_post = pid; deleted_comments }, observation)

let apply store plan =
  let post_id = Post_id.to_string plan.deleted_post in
  let comments = List.fold_left (fun ids id -> String_set.add (Comment_id.to_string id) ids)
    String_set.empty plan.deleted_comments in
  (* Validate every fixed ID before changing any table. A reused ID must not
     delete another thread, and newly observed children are outside this plan. *)
  let wrong_parent = List.exists (fun id ->
    match Hashtbl.find_opt store.comments (Comment_id.to_string id) with
    | None -> false
    | Some comment -> not (String.equal (Post_id.to_string comment.post_id) post_id)) plan.deleted_comments in
  if wrong_parent then Error (Io_error "Board deletion comment ownership changed.")
  else (
    (match Hashtbl.find_opt store.posts post_id with
     | None -> ()
     | Some post ->
       unindex_post_origin store post;
       unindex_hot_post store post;
       Hashtbl.remove store.posts post_id;
       decr store.post_count);
    String_set.iter (Hashtbl.remove store.comments) comments;
    (match Hashtbl.find_opt store.comments_by_post post_id with
     | None -> ()
     | Some ids ->
       let remaining = List.filter (fun id -> not (String_set.mem id comments)) ids in
       match remaining with
       | [] -> Hashtbl.remove store.comments_by_post post_id
       | _ :: _ -> Hashtbl.replace store.comments_by_post post_id remaining);
    let votes = Hashtbl.fold (fun key _ keys ->
      match Board_vote_key.of_string key with
      | None -> keys
      | Some vote ->
        let remove = match Board_vote_key.target_kind vote with
          | Board_vote_key.Post -> String.equal (Board_vote_key.target_id vote) post_id
          | Board_vote_key.Comment -> String_set.mem (Board_vote_key.target_id vote) comments in
        if remove then key :: keys else keys) store.vote_log [] in
    let reactions = Hashtbl.fold (fun key (reaction : reaction) keys ->
      let remove = match reaction.target_type with
        | Reaction_post -> String.equal reaction.target_id post_id
        | Reaction_comment -> String_set.mem reaction.target_id comments in
      if remove then key :: keys else keys) store.reactions [] in
    List.iter (Hashtbl.remove store.vote_log) votes;
    List.iter (Hashtbl.remove store.reactions) reactions;
    invalidate_post_caches store;
    invalidate_comment_caches store;
    Ok ())

let retire store work =
  let outcome = Source.clear store work.decision_receipt in
  let result = match outcome with
    | Source.Cleared _ -> Ok Durable_deletion
    | Source.Recorded _ | Source.Not_written _ | Source.Unknown _ ->
      Ok (Deletion_persistence_pending pending_detail) in
  Source.finish outcome result

let persist_applied store work batch =
  let outcome = Batch.persist batch ~write:(write_snapshot store) in
  let retries = Batch.retries outcome in
  let next = { work with deletion_progress = Sources_written } in
  with_lock store (fun () ->
    List.iter (remark store) retries;
    match retries with
    | [] -> store.deletion_state <- Deletion_pending next
    | _ :: _ -> ());
  (* Preserve the known four-write result before a reserved cleanup escapes.
     Retirement IO must not occur in that interrupted settlement. *)
  Batch.finish_settlement outcome;
  match retries with
  | [] -> retire store next
  | _ :: _ -> Ok (Deletion_persistence_pending pending_detail)

let project store work action =
  try with_lock store action with exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    store.deletion_state <- Deletion_projection_failed {
      receipt = work.decision_receipt; exception_; backtrace };
    Printexc.raise_with_backtrace exception_ backtrace

let resume store work = match work.deletion_progress with
  | Sources_written -> retire store work
  | Decision_recorded | Model_applied ->
    match require_sources store with
    | Error _ ->
      (match work.deletion_progress with
       | Decision_recorded -> Ok (Deletion_decision_pending pending_detail)
       | Model_applied | Sources_written -> Ok (Deletion_persistence_pending pending_detail))
    | Ok () ->
      let staged = project store work (fun () ->
        let* () = match work.deletion_progress with
          | Decision_recorded -> apply store work.decision_receipt.decision
          | Model_applied | Sources_written -> Ok () in
        let applied = { work with deletion_progress = Model_applied } in
        store.deletion_state <- Deletion_pending applied;
        Ok (applied, capture store Batch.for_delete)) in
      match staged with
      | Error error ->
        store.deletion_state <- Deletion_pending { work with
          deletion_last_failure = Some (Deletion_projection_rejected error) };
        Ok (Deletion_decision_pending pending_detail)
      | Ok (applied, batch) -> persist_applied store applied batch

let delete_post store ~authorization ~post_id =
  let* pid = Post_id.of_string post_id in
  with_persist_lock store (fun () ->
    let* () = require_sources store in
    let* () = Source.require_empty store in
    let* plan, parent = with_lock store (fun () -> stage store ~authorization pid) in
    let recorded = Source.record store ~parent plan in
    match recorded with
    | Source.Not_written _ | Source.Cleared _ ->
      Source.finish recorded (Error (Io_error
        "Board deletion was not recorded. Refresh Board data before requesting deletion again."))
    | Source.Unknown _ -> Source.finish recorded (Ok (Deletion_decision_pending pending_detail))
    | Source.Recorded _ ->
      let* () = Source.finish recorded (Ok ()) in
      match store.deletion_state with
      | Deletion_pending work -> resume store work
      | Deletion_unobserved | Deletion_readable _ | Deletion_unsettled _
      | Deletion_refused _ | Deletion_projection_failed _ -> Ok (Deletion_decision_pending pending_detail))

let recover_on_initialize store =
  with_persist_lock store (fun () ->
    let* plan = Source.load store in
    match plan with
    | None -> Ok ()
    | Some _ ->
      let* () = require_sources store in
      let recorded = Source.fence_recovery store in
      let* () = Source.finish recorded (match recorded with
        | Source.Recorded _ -> Ok ()
        | Source.Cleared _ | Source.Not_written _ | Source.Unknown _ -> Error (Io_error pending_detail)) in
      match store.deletion_state with
      | Deletion_pending work ->
        let* outcome = resume store work in
        (match outcome with
         | Durable_deletion -> Ok ()
         | Deletion_decision_pending _ | Deletion_persistence_pending _ -> Error (Io_error pending_detail))
      | Deletion_unobserved | Deletion_readable _ | Deletion_unsettled _
      | Deletion_refused _ | Deletion_projection_failed _ -> Error (Io_error pending_detail))

let flush_independent store =
  let* () = Source.require_empty store in
  let batch = with_lock store (fun () ->
    capture store (Batch.for_flush ~dirty_posts:store.dirty_posts ~dirty_comments:store.dirty_comments
      ~votes_readable:(Result.is_ok (Board_votes_source.require_readable store))
      ~reactions_readable:(Result.is_ok (Board_reactions_source.require_readable store)))) in
  let outcome = Batch.persist batch ~write:(fun content ->
    let result = write_snapshot store content in
    (match result with
     | Ok () -> ()
     | Error _ -> with_lock store (fun () -> remark store (Batch.retry_for_kind (Batch.kind_of_payload content))));
    result) in
  with_lock store (fun () -> List.iter (remark store) (Batch.retries outcome));
  Batch.finish_settlement outcome;
  match Batch.errors outcome with [] -> Ok () | error :: _ -> Error error

let flush_dirty store =
  with_persist_lock store (fun () ->
    let flush_current () =
      let dirty = with_lock store (fun () -> store.dirty_posts || store.dirty_comments) in
      if dirty then flush_independent store else Ok () in
    let result = match store.deletion_state with
      | Deletion_pending work ->
        let* outcome = resume store work in
        (match outcome with
         | Durable_deletion -> flush_current ()
         | Deletion_decision_pending _ | Deletion_persistence_pending _ -> Error (Io_error pending_detail))
      | Deletion_unsettled _ | Deletion_refused _ | Deletion_projection_failed _
      | Deletion_readable { plan = Some _; _ } -> Error (Io_error pending_detail)
      | Deletion_unobserved | Deletion_readable { plan = None; _ } ->
        flush_current () in
    match result with
    | Ok () -> ()
    | Error error -> record_persist_error ~where:"flush-deletion" (show_board_error error))
