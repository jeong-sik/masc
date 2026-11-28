open Board_core_persist
open Result.Syntax

(* A thread's comments in the order they were written. [created_at] alone
   leaves comments stamped in the same instant in whatever order the post's
   index holds them, so two reads could disagree about which of them comes
   first. The id settles that tie the same way on every read. The thread read
   pages through this order by offset, and a Keeper wake names the replies
   after its own comment by where they start in it, so both reads must agree. *)
let compare_comments_oldest_first (a : comment) (b : comment) =
  match Stdlib.Float.compare a.created_at b.created_at with
  | 0 -> String.compare (Comment_id.to_string a.id) (Comment_id.to_string b.id)
  | order -> order
;;

(* The per-post comment list with expired rows excluded — the same visibility
   the sweeper enforces. Runs under the store lock; does not mutate
   anything. *)
let live_comments_unlocked store pid =
  let now = Time_compat.now () in
  let comment_keys =
    match Hashtbl.find_opt store.comments_by_post (Post_id.to_string pid) with
    | None -> []
    | Some keys -> keys
  in
  List.filter_map
    (fun key ->
       match Hashtbl.find_opt store.comments key with
       | Some { expires_at; _ } when
           Stdlib.Float.compare expires_at 0.0 > 0
           && Stdlib.Float.compare expires_at now < 0 -> None
       | found -> found)
    comment_keys
;;

(* task-1758/#39356 scope extension: a post holding Limits.comment_count_cap
   live comments refuses the next one, with the same "open a successor post"
   guidance a closed thread gives. The count is the live per-post comment
   list, so threads whose timed comments have aged out keep accepting new
   ones. Runs under the store lock (the staging/commit write boundary holds
   it); does not mutate anything. *)
let comment_count_cap_error_unlocked store pid =
  let cap = Limits.comment_count_cap in
  if cap <= 0 then None
  else
    let live = List.length (live_comments_unlocked store pid) in
    if live >= cap
    then
      Some
        (Printf.sprintf
           "Post %s has reached the comment cap of %d; open a successor post"
           (Post_id.to_string pid) cap)
    else None
;;

(* A live comment on the post from the same author, under the same parent,
   with byte-identical text already says what the new one would say. A Keeper
   turn that kept re-posting one body wrote 390 comments of 39 distinct bodies
   on 5 posts (turn 5517, 2026-11-14). The refusal names the existing comment
   so the writer sees why nothing was posted; a different body, parent or
   author is not a repeat. Runs under the store lock before the durable
   append; does not mutate anything. *)
let duplicate_comment_error_unlocked store pid ~author_id ~parent_cid ~content =
  let author = Agent_id.to_string author_id in
  let same_parent existing =
    match existing, parent_cid with
    | None, None -> true
    | Some a, Some b -> String.equal (Comment_id.to_string a) (Comment_id.to_string b)
    | None, Some _ | Some _, None -> false
  in
  let repeats (existing : comment) =
    String.equal (Agent_id.to_string existing.author) author
    && same_parent existing.parent_id
    && String.equal existing.content content
  in
  Option.map
    (fun (existing : comment) ->
       Printf.sprintf
         "Post %s already has this exact comment from %s as %s; it was not \
          posted again. Change the text or reply under a different comment"
         (Post_id.to_string pid) author (Comment_id.to_string existing.id))
    (List.find_opt repeats (live_comments_unlocked store pid))
;;

(* A reply names a comment of the post it is written on: a row the thread read
   of that post lists. The thread read pages one post's comments and the Keeper
   wake for a reply looks its parent up in that same list, so a parent held by
   another post, or by none, leaves a reply neither of them can place.

   Membership follows the thread read, not the comment cap: a timed comment
   stays a parent for as long as the listing shows it, which is until the
   sweeper removes its row.

   One refusal covers a comment of another post and an id that names no
   comment. Telling the two apart would tell a writer of this post whether an
   id is a comment of a post it may not read. Stored replies of the first kind
   were written through masc_board_comment with an id read on a neighbouring
   thread, so the message says where a reply goes instead of calling the id
   made up.

   Runs under the store lock; does not mutate anything. *)
let require_reply_parent_unlocked store pid parent_cid =
  match parent_cid with
  | None -> Ok ()
  | Some parent ->
    let wanted = Comment_id.to_string parent in
    let asked = Post_id.to_string pid in
    let listed =
      Hashtbl.mem store.comments wanted
      &&
      match Hashtbl.find_opt store.comments_by_post asked with
      | None -> false
      | Some keys -> List.exists (String.equal wanted) keys
    in
    if listed
    then Ok ()
    else
      Error
        (Validation_error
           (Printf.sprintf
              "parent_id is not a comment in the listing of post %s. A reply goes \
               on the post whose masc_board_post_get listing returned its parent: \
               reply there, or leave parent_id out to comment on post %s"
              asked asked))
;;

let add_comment_with_audience
      store
      ~reader
      ~lookup
      ~post_id
      ~author
      ~content
      ?parent_id
      ?(ttl_hours = Limits.default_ttl_hours)
      ?(attachment_ids = [])
      ()
  : (comment_creation, board_error) Result.t
  =
  maybe_sweep store;
  (* Validate all IDs first *)
  let* pid = Post_id.of_string post_id in
  let* author_id = Agent_id.of_string author in
  let* parent_cid =
    match parent_id with
    | None -> Ok None
    | Some p ->
      let* cid = Comment_id.of_string p in
      Ok (Some cid)
  in
  (* Validate content *)
  if ttl_hours < 0
  then Error (Validation_error "ttl_hours must be non-negative")
  else if String.length content = 0
  then Error (Validation_error "Content cannot be empty")
  else
    let* audience, unresolved = Board_audience.audience_for_comment ~lookup ~content in
    (* Write-ahead (PR #28934 class, #28952): validate under [with_lock]
       with no mutation, then hold the persistence lock across the durable
       append and commit under [with_lock] from a fresh read. The previous shape mutated
       first and appended second, so a racing [flush_dirty] could
       snapshot-write a comment whose durable append was about to fail
       and be rolled back — reviving it from the snapshot on restart.
       If staging rejects or the append fails, nothing was mutated, so
       there is nothing to roll back. *)
    let staged =
      with_lock store (fun () ->
        match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
        | None -> Error (Post_not_found post_id)
        | Some post ->
          let* () = Board_comment_admission.validate_parent ~reader ~post_id ~audience post in
          let* () = require_reply_parent_unlocked store pid parent_cid in
          (match comment_count_cap_error_unlocked store pid with
           | Some msg -> Error (Validation_error msg)
           | None ->
          (match
             duplicate_comment_error_unlocked store pid ~author_id ~parent_cid ~content
           with
           | Some msg -> Error (Validation_error msg)
           | None ->
          (match
             validate_sub_board_post_policy_unlocked
               store
               ~author_id
               ~hearth:post.hearth
           with
           | Error e -> Error e
           | Ok () ->
             let now = Time_compat.now () in
             Ok
               { id = Comment_id.generate ()
               ; post_id = pid
               ; parent_id = parent_cid
               ; author = author_id
               ; content
               ; audience = Some audience
               ; created_at = now
               ; expires_at =
                   (if ttl_hours = 0
                    then 0.0
                    else
                      now
                      +. (Stdlib.Float.of_int ttl_hours
                          *. Masc_time_constants.hour))
               ; votes_up = 0
               ; votes_down = 0
               ; attachment_ids
               }))))
    in
    (match staged with
     | Error _ as e -> e
     | Ok comment ->
        with_persist_lock store (fun () ->
          (* A display-only parent cannot authorize a durable comment or its
             later participant routing. Check before the append while holding
             the same lock that serializes the posts source. *)
          let* () = require_posts_source_readable store in
          (* Staging read the parent before this lock was held, and a sweep
             that ran in between may have removed it for its TTL. The sweep
             holds this persistence lock for its whole pass, so a parent that
             is listed here stays listed until the reply is committed.
             Refusing here means such a reply is never written. *)
          let* () =
            with_lock store (fun () ->
              require_reply_parent_unlocked store pid parent_cid)
          in
          let* receipt = append_comment store ~reader comment in
          let committed = with_lock store (fun () ->
              (* Commit from a fresh read: the post can change or vanish
                 while the append is in flight; bumping the stale staged
                 copy would clobber a concurrent unrelated mutation. The
                 source read-set already authorized the durable append.
                 Recheck the model before publishing its counters/routing. *)
              match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
              | None -> Error (Post_not_found post_id)
              | Some post ->
                let* () = Board_comment_admission.validate_parent ~reader ~post_id ~audience post in
                (* Read again from the model this commit publishes, like the
                   checks around it. The sweep is not what this guards
                   against: the check before the append already covers it. *)
                let* () = require_reply_parent_unlocked store pid parent_cid in
                (match comment_count_cap_error_unlocked store pid with
                 | Some msg -> Error (Validation_error msg)
                 | None ->
                (match
                   validate_sub_board_post_policy_unlocked
                     store
                     ~author_id
                     ~hearth:post.hearth
                 with
                 | Error _ as e -> e
                 | Ok () ->
                   let post_key = Post_id.to_string pid in
                   let comment_key = Comment_id.to_string comment.id in
                   Hashtbl.add store.comments comment_key comment;
                   let existing =
                     Hashtbl.find_opt store.comments_by_post post_key
                     |> Option.value ~default:[]
                   in
                   Hashtbl.replace
                     store.comments_by_post
                     post_key
                     (comment_key :: existing);
                   put_post store
                     { post with
                       reply_count = post.reply_count + 1
                     ; updated_at =
                         (* Never move [updated_at] backwards: a
                            concurrent mutation can land between staging
                            and commit with a newer timestamp. *)
                         Stdlib.Float.max post.updated_at comment.created_at
                     };
                   mark_dirty_post store post_key;
                   mark_dirty_comment store comment_key;
                   invalidate_post_caches store;
                   invalidate_comment_caches store;
                   Ok { comment; audience; unresolved }))) in
          (* A normal typed rejection precedes every model mutation above.
             Record deletion of our own appended row before acknowledging
             its known receipt. An exception leaves publication unfinished. *)
          (match committed with
           | Ok _ -> ()
           | Error _ -> with_lock store (fun () ->
               mark_dirty_comment store (Comment_id.to_string comment.id)));
          let* () = publish_comment_append store receipt in
          (match committed with
           | Ok _ as ok -> ok
           | Error _ as error ->
             (* Retain the same persistence interval and exact append receipt.
                A foreign append makes cleanup CAS fail instead of deleting
                its rows. Dirty retry is volatile; a restart or a
                reobservation before cleanup can still reload this rejected
                row (#26378, #55449). *)
             rewrite_comments_under_persistence store;
             error)))
;;

let add_comment store ~reader ~lookup ~post_id ~author ~content ?parent_id ?ttl_hours ?attachment_ids () =
  add_comment_with_audience
    store
    ~reader
    ~lookup
    ~post_id
    ~author
    ~content
    ?parent_id
    ?ttl_hours
    ?attachment_ids
    ()
  |> Result.map (fun creation -> creation.comment)
;;

(* Both the rows and their absence authority belong to this one locked view. *)
let observe_comments_unlocked store pid : comments_observation =
  let post_key = Post_id.to_string pid in
  let comment_ids =
    Hashtbl.find_opt store.comments_by_post post_key |> Option.value ~default:[]
  in
  let comments =
    List.filter_map (fun cid -> Hashtbl.find_opt store.comments cid) comment_ids
    |> List.sort compare_comments_oldest_first
  in
  let completeness = match require_comments_source_readable store with
    | Ok () -> Source_complete
    | Error error -> Source_incomplete error
  in
  { comments; completeness }
;;

let observe_comments store ~post_id : (comments_observation, board_read_error) Result.t =
  maybe_sweep store;
  match Post_id.of_string_for_read post_id with
  | Error e -> Error e
  | Ok pid ->
    with_persist_lock store (fun () ->
      with_lock store (fun () -> Ok (observe_comments_unlocked store pid)))
;;

let read_comments store ~post_id : (comment list, board_read_error) Result.t =
  let* observation = observe_comments store ~post_id in
  match observation.completeness with
  | Source_complete -> Ok observation.comments
  | Source_incomplete error -> Error (Read_source_unavailable error)
;;

let get_comment store ~comment_id : (comment, board_error) Result.t =
  maybe_sweep store;
  match Comment_id.of_string comment_id with
  | Error e -> Error e
  | Ok cid ->
    with_persist_lock store (fun () ->
      match require_comments_source_readable store with
      | Error error -> Error (board_error_of_read_error (Read_source_unavailable error))
      | Ok () ->
        with_lock store (fun () ->
          let comment_key = Comment_id.to_string cid in
          match Hashtbl.find_opt store.comments comment_key with
          | Some comment -> Ok comment
          | None -> Error (Comment_not_found comment_id)))
;;

let list_newest_comments_unlocked store ?predicate ~limit () : comment list =
  let limit = max 0 limit in
  let total = Hashtbl.length store.comments in
  if limit = 0 || total = 0 then []
  else
    let matches comment =
      match predicate with
      | None -> true
      | Some pred -> pred comment
    in
    if limit >= 4096 || limit >= total / 4 then
      let all =
        Hashtbl.fold
          (fun _ (c : comment) acc -> if matches c then c :: acc else acc)
          store.comments
          []
      in
      let sorted =
        List.sort
          (fun (a : comment) (b : comment) -> compare_comments_oldest_first b a)
          all
      in
      take limit sorted
    else begin
      (* Bounded min-heap of the [limit] newest matching comments so the root
         holds the oldest kept comment. Non-qualifying older rows perform a
         single comparison with zero heap allocation. *)
      let heap_opt : comment array option ref = ref None in
      let size = ref 0 in
      let sift_up heap idx =
        let i = ref idx in
        while !i > 0 do
          let p = (!i - 1) lsr 1 in
          if compare_comments_oldest_first heap.(!i) heap.(p) < 0 then begin
            let tmp = heap.(!i) in
            heap.(!i) <- heap.(p);
            heap.(p) <- tmp;
            i := p
          end else
            i := 0
        done
      in
      let sift_down heap len =
        let i = ref 0 in
        let continue = ref true in
        while !continue do
          let left = (!i lsl 1) + 1 in
          if left >= len then
            continue := false
          else begin
            let right = left + 1 in
            let smallest =
              if right < len && compare_comments_oldest_first heap.(right) heap.(left) < 0
              then right
              else left
            in
            if compare_comments_oldest_first heap.(smallest) heap.(!i) < 0 then begin
              let tmp = heap.(!i) in
              heap.(!i) <- heap.(smallest);
              heap.(smallest) <- tmp;
              i := smallest
            end else
              continue := false
          end
        done
      in
      Hashtbl.iter
        (fun _ (c : comment) ->
           if matches c then
             match !heap_opt with
             | None ->
               let heap = Array.make limit c in
               heap_opt := Some heap;
               size := 1
             | Some heap ->
               if !size < limit then begin
                 let idx = !size in
                 heap.(idx) <- c;
                 size := idx + 1;
                 sift_up heap idx
               end else if compare_comments_oldest_first c heap.(0) > 0 then begin
                 heap.(0) <- c;
                 sift_down heap limit
               end)
        store.comments;
      match !heap_opt with
      | None -> []
      | Some heap ->
        let acc = ref [] in
        for i = 0 to !size - 1 do
          acc := heap.(i) :: !acc
        done;
        List.sort
          (fun (a : comment) (b : comment) -> compare_comments_oldest_first b a)
          !acc
    end
;;

(** List all comments (for profile aggregation) *)
let list_comments store ?(limit = 1000) () : comment list =
  maybe_sweep store;
  with_lock store (fun () -> list_newest_comments_unlocked store ~limit ())
;;
