open Board_types
open Board_core_persist
open Result.Syntax

module Source = Board_deletion_source
module Batch = Board_snapshot_batch
module String_set = Set_util.StringSet
module String_map = Map.Make (String)
module Comment_set = Set.Make (struct
  type t = Comment_id.t
  let compare left right = String.compare (Comment_id.to_string left) (Comment_id.to_string right)
end)

type deletion_authorization =
  | Operator_deletion
  | Author_deletion of { reader : Board_access.reader; author : Agent_id.t }
  | Cleanup_deletion of Board_access.reader

let pending_detail = "Board deletion recovery is pending. Do not repeat the deletion."

let require_post_sources store =
  let* () = require_posts_source_readable store in
  let* () = require_comments_source_readable store in
  let* () = Board_votes_source.require_readable store in
  Board_reactions_source.require_readable store

let require_sources store = function
  | Delete_post _ -> require_post_sources store
  | Delete_sub_board _ ->
    let* () = require_posts_source_readable store in
    Board_sub_boards_source.require_readable store

let selection = function
  | Delete_post _ -> Batch.for_delete
  | Delete_sub_board _ -> Batch.for_sub_board_delete

let policy_observation store = match store.sub_boards_source with
  | Policy_readable observation -> Ok observation
  | Policy_unobserved | Policy_publishing _ | Policy_refused _ | Policy_unsettled _ ->
    Error (Io_error "Board data is unavailable.")

let filter_policy_snapshot (snapshot : Fs_compat.private_jsonl_snapshot) ~keep =
  let rec rows reversed = function
    | [] -> Ok (String.concat "\n" (List.rev reversed))
    | text :: remaining ->
      if String.equal (String.trim text) "" then rows (text :: reversed) remaining
      else match Yojson.Safe.from_string text with
        | json ->
          (match Board_sub_board_json.sub_board_of_yojson json with
           | None -> Error (Io_error "Board data is unavailable.")
           | Some board -> rows (if keep board.id then text :: reversed else reversed) remaining)
        | exception Yojson.Json_error _ -> Error (Io_error "Board data is unavailable.") in
  rows [] (String.split_on_char '\n' snapshot.bytes)

let policy_jsonl store =
  let* observation = policy_observation store in
  (* Policy changes publish synchronously; the owned deletion is the only
     unpersisted removal. Keep all other physical rows in their original order,
     including shadowed IDs and aliases, so fresh and current indexes agree. *)
  filter_policy_snapshot observation.policy_snapshot ~keep:(fun id ->
    Hashtbl.mem store.sub_boards (Sub_board_id.to_string id))

let reactions_jsonl store =
  let buffer = Buffer.create 4096 in
  Hashtbl.iter (fun _ (reaction : reaction) ->
    Buffer.add_string buffer (Yojson.Safe.to_string (Board_core_json.reaction_to_yojson reaction));
    Buffer.add_char buffer '\n') store.reactions;
  Buffer.contents buffer

let capture store selection =
  let* batch = Batch.capture selection
    ~posts:(fun () -> capture_posts_snapshot store)
    ~comments:(fun () -> capture_comments_snapshot store)
    ~votes:(fun () -> Board_voting.vote_log_jsonl store)
    ~reactions:(fun () -> reactions_jsonl store)
    ~policy:(fun () -> policy_jsonl store) in
  if Batch.includes selection Batch.Posts then (
    Hashtbl.clear store.dirty_post_ids;
    store.dirty_posts <- false);
  if Batch.includes selection Batch.Comments then (
    Hashtbl.clear store.dirty_comment_ids;
    store.dirty_comments <- false);
  store.last_flush <- Time_compat.now ();
  Ok batch

let write_snapshot store = function
  | Batch.Posts_payload snapshot -> finish_posts_write (save_posts_snapshot store snapshot)
  | Batch.Comments_payload snapshot -> save_comments_snapshot store snapshot
  | Batch.Votes_payload bytes ->
    let* () = Board_votes_source.require_readable store in
    Board_voting.save_vote_log_jsonl store bytes
  | Batch.Reactions_payload bytes ->
    let* () = Board_reactions_source.require_readable store in
    save_reactions_jsonl_result store bytes
  | Batch.Policy_payload bytes ->
    let outcome = Board_sub_boards_source.rewrite store bytes in
    let result = match outcome with
      | Board_sub_boards_source.Written { publication; _ } ->
        Board_sub_boards_source.acknowledge_publication store publication
      | Not_written _ | Unknown _ -> Error (Io_error "Board data is unavailable.") in
    Board_sub_boards_source.finish_write outcome result

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

let posts_in_snapshot (snapshot : Fs_compat.private_jsonl_snapshot) =
  let rec rows line posts = function
    | [] -> Ok posts
    | text :: remaining ->
      match Board_posts_rows.decode ~line text with
      | Board_posts_rows.Blank -> rows (line + 1) posts remaining
      | Board_posts_rows.Rejected _ -> Error (Io_error "Board data is unavailable.")
      | Board_posts_rows.Accepted { post; _ } ->
        rows (line + 1) (String_map.add (Post_id.to_string post.id) post posts) remaining in
  rows 1 String_map.empty (String.split_on_char '\n' snapshot.bytes)

let parent_in_snapshot ~post_id snapshot =
  let* posts = posts_in_snapshot snapshot in
  match String_map.find_opt post_id posts with
  | Some post -> Ok post
  | None -> Error (Post_not_found post_id)

let policy_in_snapshot (snapshot : Fs_compat.private_jsonl_snapshot) =
  let rec rows by_id by_slug = function
    | [] -> Ok (by_id, by_slug)
    | text :: remaining ->
      if String.equal (String.trim text) "" then rows by_id by_slug remaining
      else match Yojson.Safe.from_string text with
        | json ->
          (match Board_sub_board_json.sub_board_of_yojson json with
           | None -> Error (Io_error "Board data is unavailable.")
           | Some board ->
             let id = Sub_board_id.to_string board.id in
             rows (String_map.add id board by_id) (String_map.add board.slug id by_slug) remaining)
        | exception Yojson.Json_error _ -> Error (Io_error "Board data is unavailable.") in
  rows String_map.empty String_map.empty (String.split_on_char '\n' snapshot.bytes)

let children_in_snapshot ~post_id (snapshot : Fs_compat.private_jsonl_snapshot) =
  let rec rows children = function
    | [] -> Ok (Comment_set.elements children)
    | text :: remaining ->
      if String.equal (String.trim text) "" then rows children remaining
      else
        match Yojson.Safe.from_string text with
        | json ->
          (match (Board_content_json.comment_of_yojson json).value with
           | None -> Error (Io_error "Board data is unavailable.")
           | Some comment ->
             (* Like the loader, the last accepted row owns each ID, including
                an ID whose later row no longer belongs to this parent. *)
             let children = if String.equal (Post_id.to_string comment.post_id) post_id
               then Comment_set.add comment.id children else Comment_set.remove comment.id children in
             rows children remaining)
        | exception Yojson.Json_error _ -> Error (Io_error "Board data is unavailable.") in
  rows Comment_set.empty (String.split_on_char '\n' snapshot.bytes)

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
    let* comments = match store.comments_source with
      | Comments_readable { observation; _ } -> Ok observation
      | Comments_unobserved | Comments_publishing _ | Comments_recovered _
      | Comments_refused _ | Comments_unsettled _ -> Error (Io_error "Board data is unavailable.") in
    let* deleted_comments = children_in_snapshot ~post_id comments.snapshot in
    Ok ({ decision_id = Deletion_id.generate ();
      operation = Delete_post { deleted_post = pid; deleted_comments } }, observation, comments)

let stage_sub_board store ~authorization ~sub_board_id =
  let unavailable () = Error (Io_error "Board model and source must be reloaded before deleting a sub-board.") in
  let* posts = match store.posts_source with
    | Posts_readable { observation; _ } -> Ok observation
    | Posts_unobserved | Posts_refused _ | Posts_unsettled _ -> unavailable () in
  let* policy = match store.sub_boards_source with
    | Policy_readable observation -> Ok observation
    | Policy_unobserved | Policy_publishing _ | Policy_refused _ | Policy_unsettled _ -> unavailable () in
  let* source_posts = posts_in_snapshot posts.snapshot in
  let* boards, slugs = policy_in_snapshot policy.policy_snapshot in
  let* board = match String_map.find_opt sub_board_id boards with
    | Some board -> Ok board
    | None ->
      match Option.bind (String_map.find_opt sub_board_id slugs) (fun id -> String_map.find_opt id boards) with
      | Some board -> Ok board
      | None -> Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id)) in
  let* () = match authorization with
    | Operator_sub_board_deletion -> Ok ()
    | Owner_sub_board_deletion owner ->
      if String.equal (Agent_id.to_string owner) (Agent_id.to_string board.owner) then Ok ()
      else Error (Unauthorized "Only the current owner can delete this sub-board.") in
  (* Only vote/reply counters and their activity time are deferred projections.
     A source-only settlement cannot lend a fresh cursor to an older model. *)
  let coherent_posts = String_map.cardinal source_posts = Hashtbl.length store.posts
    && String_map.for_all (fun id (canonical : post) ->
      match Hashtbl.find_opt store.posts id with
      | None -> false
      | Some cached ->
        { cached with votes_up = canonical.votes_up; votes_down = canonical.votes_down;
          reply_count = canonical.reply_count; updated_at = canonical.updated_at } = canonical) source_posts in
  let coherent_policy = String_map.cardinal boards = Hashtbl.length store.sub_boards
    && String_map.for_all (fun id (canonical : sub_board) ->
      match Hashtbl.find_opt store.sub_boards id with
      | None -> false
      | Some cached -> { cached with post_count = canonical.post_count } = canonical) boards
    && String_map.cardinal slugs = Hashtbl.length store.sub_boards_by_slug
    && String_map.for_all (fun slug id ->
      match Hashtbl.find_opt store.sub_boards_by_slug slug with
      | None -> false | Some cached -> String.equal cached id) slugs in
  if not (coherent_posts && coherent_policy) then unavailable ()
  else
    let owns_slug = Option.equal String.equal (String_map.find_opt board.slug slugs)
      (Some (Sub_board_id.to_string board.id)) in
    let unlinked_posts = if owns_slug then
      String_map.fold (fun _ (post : post) ids ->
        if Option.equal String.equal post.hearth (Some board.slug) then post.id :: ids else ids)
        source_posts [] |> List.rev
      else [] in
    Ok ({ decision_id = Deletion_id.generate (); operation = Delete_sub_board {
      deleted_sub_board = board.id; deleted_slug = board.slug; unlinked_posts } }, posts, policy)

let apply_post store ~deleted_post ~deleted_comments =
  let post_id = Post_id.to_string deleted_post in
  let comments = List.fold_left (fun ids id -> String_set.add (Comment_id.to_string id) ids)
    String_set.empty deleted_comments in
  (* Validate every fixed ID before changing any table. A reused ID must not
     delete another thread, and newly observed children are outside this plan. *)
  let wrong_parent = List.exists (fun id ->
    match Hashtbl.find_opt store.comments (Comment_id.to_string id) with
    | None -> false
    | Some comment -> not (String.equal (Post_id.to_string comment.post_id) post_id)) deleted_comments in
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

let apply_sub_board store ~deleted_sub_board ~deleted_slug ~unlinked_posts =
  let id = Sub_board_id.to_string deleted_sub_board in
  let* () = match Hashtbl.find_opt store.sub_boards id with
    | None -> Ok ()
    | Some board when String.equal board.slug deleted_slug -> Ok ()
    | Some _ -> Error (Io_error "Board deletion sub-board identity changed.") in
  let* policy = policy_observation store in
  let* remaining_bytes = filter_policy_snapshot policy.policy_snapshot ~keep:(fun candidate ->
    not (String.equal (Sub_board_id.to_string candidate) id)) in
  let* _, remaining_slugs = policy_in_snapshot { policy.policy_snapshot with bytes = remaining_bytes } in
  Hashtbl.remove store.sub_boards id;
  Hashtbl.clear store.sub_boards_by_slug;
  String_map.iter (fun slug owner -> Hashtbl.replace store.sub_boards_by_slug slug owner) remaining_slugs;
  List.iter (fun pid ->
    let key = Post_id.to_string pid in
    match Hashtbl.find_opt store.posts key with
    | Some post when Option.equal String.equal post.hearth (Some deleted_slug) ->
      Hashtbl.replace store.posts key { post with hearth = None }
    | Some _ | None -> ()) unlinked_posts;
  invalidate_post_caches store;
  Ok ()

let apply store plan = match plan.operation with
  | Delete_post { deleted_post; deleted_comments } -> apply_post store ~deleted_post ~deleted_comments
  | Delete_sub_board { deleted_sub_board; deleted_slug; unlinked_posts } ->
    apply_sub_board store ~deleted_sub_board ~deleted_slug ~unlinked_posts

let source_effect_uncertain store operation =
  let posts = match store.posts_source with
    | Posts_unsettled _ -> true
    | Posts_unobserved | Posts_readable _ | Posts_refused _ -> false in
  match operation with
  | Delete_sub_board _ ->
    posts || (match store.sub_boards_source with
      | Policy_unsettled _ | Policy_publishing _ -> true
      | Policy_unobserved | Policy_readable _ | Policy_refused _ -> false)
  | Delete_post _ ->
    posts || (match store.comments_source with
      | Comments_unsettled _ | Comments_publishing _ | Comments_recovered _ -> true
      | Comments_unobserved | Comments_readable _ | Comments_refused _ -> false)
    || (match store.votes_source with
      | Votes_unsettled _ | Votes_publishing _ -> true
      | Votes_unobserved | Votes_readable _ | Votes_refused _ -> false)
    || (match store.reactions_source with
      | Reactions_unsettled _ | Reactions_publishing _ -> true
      | Reactions_unobserved | Reactions_readable _ | Reactions_refused _ -> false)

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
  let uncertain = source_effect_uncertain store work.decision_receipt.decision.operation in
  let next = { work with deletion_progress = Sources_written } in
  with_lock store (fun () ->
    List.iter (remark store) retries;
    match retries with
    | [] -> store.deletion_state <- Deletion_pending next
    | _ :: _ ->
      if uncertain then store.deletion_state <- Deletion_pending {
        work with deletion_progress = Sources_uncertain } );
  (* Preserve every selected known write before a reserved cleanup escapes.
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
  | Sources_uncertain -> Ok (Deletion_persistence_pending pending_detail)
  | Decision_recorded | Model_applied ->
    match require_sources store work.decision_receipt.decision.operation with
    | Error _ ->
      (match work.deletion_progress with
       | Decision_recorded -> Ok (Deletion_decision_pending pending_detail)
       | Model_applied | Sources_uncertain | Sources_written -> Ok (Deletion_persistence_pending pending_detail))
    | Ok () ->
      let staged = project store work (fun () ->
        let* () = match work.deletion_progress with
          | Decision_recorded -> apply store work.decision_receipt.decision
          | Model_applied | Sources_uncertain | Sources_written -> Ok () in
        let applied = { work with deletion_progress = Model_applied } in
        store.deletion_state <- Deletion_pending applied;
        let* batch = capture store (selection work.decision_receipt.decision.operation) in
        Ok (applied, batch)) in
      match staged with
      | Error error ->
        (match store.deletion_state with
         | Deletion_pending current ->
           store.deletion_state <- Deletion_pending { current with
             deletion_last_failure = Some (Deletion_projection_rejected error) };
           (match current.deletion_progress with
            | Decision_recorded -> Ok (Deletion_decision_pending pending_detail)
            | Model_applied | Sources_uncertain | Sources_written ->
              Ok (Deletion_persistence_pending pending_detail))
         | Deletion_unobserved | Deletion_readable _ | Deletion_unsettled _
         | Deletion_refused _ | Deletion_projection_failed _ ->
           Ok (Deletion_decision_pending pending_detail))
      | Ok (applied, batch) -> persist_applied store applied batch

let delete_post store ~authorization ~post_id =
  let* pid = Post_id.of_string post_id in
  with_persist_lock store (fun () ->
    let* () = require_post_sources store in
    let* () = Source.require_empty store in
    let* plan, parent, comments = with_lock store (fun () -> stage store ~authorization pid) in
    let recorded = Source.record store ~readset:(Source.Post_readset { parent; comments }) plan in
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

let delete_sub_board store ~authorization ~sub_board_id =
  with_persist_lock store (fun () ->
    let* () = require_posts_source_readable store in
    let* () = Board_sub_boards_source.require_readable store in
    let* () = Source.require_empty store in
    let* plan, posts, policy = with_lock store (fun () -> stage_sub_board store ~authorization ~sub_board_id) in
    let recorded = Source.record store ~readset:(Source.Sub_board_readset { posts; policy }) plan in
    match recorded with
    | Source.Not_written _ | Source.Cleared _ ->
      Source.finish recorded (Error (Io_error "Sub-board deletion was not recorded. Refresh Board data before requesting deletion again."))
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
    | Some plan ->
      let* () = require_sources store plan.operation in
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
  let* batch = with_lock store (fun () ->
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
