(* Board Core — JSONL store logic and persistence.
   Types in Board_types. Persist + sweep extracted to
   [Board_core_persist] (godfile decomp). *)

include Board_core_persist

(* Every id parse and policy check in this module already returns
   [(_, board_error) result] and the failure is always forwarded unchanged, so
   the arms that spell that out by hand ([| Error e -> Error e]) are
   [Result.bind] written out. Binding them keeps the happy path at one
   indentation level. *)
open Result.Syntax


let read_post store ~post_id : (post, board_read_error) Result.t =
  maybe_sweep store;
  match Post_id.of_string_for_read post_id with
  | Error e -> Error e
  | Ok pid ->
    with_lock store (fun () ->
      match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
      | Some post -> Ok post
      | None -> Error (Read_post_not_found post_id))
;;

(* RFC-0233 §7 guard #2: exact O(1) index lookups, mirroring [read_post] by
   primary key. The index is keyed on the full join string (turn_ref =
   "trace#turn", or the fusion run_id) — never a meta_json substring or a
   time-window heuristic. A miss returns [None] (no scan, no false positive). *)
let find_post_by_turn_ref store ~turn_ref : post option =
  maybe_sweep store;
  with_lock store (fun () ->
    match Hashtbl.find_opt store.posts_by_turn_ref turn_ref with
    | None -> None
    | Some pid -> Hashtbl.find_opt store.posts pid)
;;

let find_post_by_run_id store ~run_id : post option =
  maybe_sweep store;
  with_lock store (fun () ->
    match Hashtbl.find_opt store.posts_by_run_id run_id with
    | None -> None
    | Some pid -> Hashtbl.find_opt store.posts pid)
;;

let list_posts_by_run_origin store =
  maybe_sweep store;
  with_lock store (fun () ->
    Hashtbl.fold (fun _ pid posts ->
      match Hashtbl.find_opt store.posts pid with
      | Some post -> post :: posts
      | None -> posts) store.posts_by_run_id [])
  |> List.sort (fun (left : post) (right : post) ->
       match Float.compare right.created_at left.created_at with
       | 0 -> String.compare (Post_id.to_string left.id) (Post_id.to_string right.id)
       | order -> order)
;;

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

(* Reads post + comments under a single critical section. The previous
   two-call sequence (read_post then read_comments) acquired
   [store.mutex] twice with [maybe_sweep] dispatching to the flusher
   actor between releases. That race window surfaces as
   [Mutex.lock: Resource deadlock avoided] under contended
   repeated agent board-read traffic. Coalescing
   keeps the read atomic, removes one [maybe_sweep] dispatch, and
   eliminates the inter-call lock churn. *)
let read_post_and_comments store ~post_id
  : (post * comment list, board_read_error) Result.t =
  maybe_sweep store;
  match Post_id.of_string_for_read post_id with
  | Error e -> Error e
  | Ok pid ->
    with_lock store (fun () ->
      let post_key = Post_id.to_string pid in
      match Hashtbl.find_opt store.posts post_key with
      | None -> Error (Read_post_not_found post_id)
      | Some post ->
        let comment_ids =
          Hashtbl.find_opt store.comments_by_post post_key |> Option.value ~default:[]
        in
        let comments =
          List.filter_map (fun cid -> Hashtbl.find_opt store.comments cid) comment_ids
        in
        Ok (post, List.sort compare_comments_oldest_first comments))
;;

let list_posts store ?(visibility_filter = None) ?hearth ?(limit = 50) () : post list =
  maybe_sweep store;
  with_lock store (fun () ->
    let limit = max 0 limit in
    if limit = 0
    then []
    else (
      let hearth_norm =
        Option.map (fun h -> String.lowercase_ascii (String.trim h)) hearth
      in
      let matches_filters (p : post) =
        (match visibility_filter with
         | None -> true
         | Some v -> p.visibility = v)
        &&
        match hearth_norm with
        | None -> true
        | Some h_norm -> Option.equal String.equal p.hearth (Some h_norm)
      in
      let rec collect seq remaining acc =
        if remaining <= 0
        then List.rev acc
        else (
          match seq () with
          | Seq.Nil -> List.rev acc
          | Seq.Cons ((key : hot_post_key), rest) ->
            (match Hashtbl.find_opt store.posts key.post_id with
             | Some post when matches_filters post ->
               collect rest (remaining - 1) (post :: acc)
             | Some _ -> collect rest remaining acc
             | None ->
               store.hot_post_index <- Hot_post_set.remove key store.hot_post_index;
               collect rest remaining acc))
      in
      collect (Hot_post_set.to_seq store.hot_post_index) limit []))
;;

let current_post_cursor store =
  maybe_sweep store;
  with_lock store (fun () ->
    match
      Hashtbl.fold
        (fun _ (candidate : post) latest ->
           match latest with
           | None -> Some candidate
           | Some (current : post) ->
             let updated_cmp =
               Stdlib.Float.compare candidate.updated_at current.updated_at
             in
             if updated_cmp > 0
                || (updated_cmp = 0
                    && String.compare
                         (Post_id.to_string candidate.id)
                         (Post_id.to_string current.id)
                       > 0)
             then Some candidate
             else latest)
        store.posts
        None
    with
    | Some post -> post.updated_at, Some (Post_id.to_string post.id)
    | None -> Time_compat.now (), None)
;;

(** Lazily traverses [store.recent_post_index] ([created_at DESC, post_id ASC])
    and collects up to [limit] posts satisfying [predicate] without sorting the
    full post table. *)
let search_posts store ~predicate ~limit : post list =
  maybe_sweep store;
  with_lock store (fun () ->
    let limit = max 0 limit in
    if limit = 0
    then []
    else (
      let rec collect seq remaining acc =
        if remaining <= 0
        then List.rev acc
        else (
          match seq () with
          | Seq.Nil -> List.rev acc
          | Seq.Cons ((key : recent_post_key), rest) ->
            (match Hashtbl.find_opt store.posts key.recent_post_id with
             | Some post when predicate post ->
               collect rest (remaining - 1) (post :: acc)
             | Some _ -> collect rest remaining acc
             | None ->
               store.recent_post_index <-
                 Recent_post_set.remove key store.recent_post_index;
               collect rest remaining acc))
      in
      collect (Recent_post_set.to_seq store.recent_post_index) limit []))
;;

(** {1 Comment Operations} *)

(* task-1758/#39356 completion criterion 2: the closed-post comment
   rejection must name the successor when one was recorded, so an agent
   whose comment is refused sees where the conversation continues instead
   of a dead end. *)
let closed_post_rejection_message ~post_id (closed : post_close_state) =
  match closed.successor_id with
  | Some sid ->
    Printf.sprintf
      "Post %s is closed; see successor %s"
      post_id
      (Post_id.to_string sid)
  | None -> Printf.sprintf "Post %s is closed" post_id
;;

(* task-1758/#39356 scope extension: a post holding Limits.comment_count_cap
   live comments refuses the next one, with the same "open a successor post"
   guidance a closed thread gives. The count is the live per-post comment
   list with expired rows excluded — the same visibility the sweeper
   enforces — so threads whose timed comments have aged out keep accepting
   new ones. Runs under the store lock (the staging/commit write boundary
   holds it); does not mutate anything. *)
let comment_count_cap_error_unlocked store pid =
  let cap = Limits.comment_count_cap in
  if cap <= 0 then None
  else
    let now = Time_compat.now () in
    let comment_keys =
      match Hashtbl.find_opt store.comments_by_post (Post_id.to_string pid) with
      | None -> []
      | Some keys -> keys
    in
    let live =
      List.fold_left
        (fun n key ->
           match Hashtbl.find_opt store.comments key with
           | Some { expires_at; _ } when
               Stdlib.Float.compare expires_at 0.0 > 0
               && Stdlib.Float.compare expires_at now < 0 -> n
           | Some _ -> n + 1
           | None -> n)
        0 comment_keys
    in
    if live >= cap
    then
      Some
        (Printf.sprintf
           "Post %s has reached the comment cap of %d; open a successor post"
           (Post_id.to_string pid) cap)
    else None
;;

let add_comment_with_audience
      store
      ~lookup
      ~post_id
      ~author
      ~content
      ?parent_id
      ?(ttl_hours = Limits.default_ttl_hours)
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
        | Some { closed = Some closed; _ } ->
          (* task-1758/#39356: a closed thread does not grow. Checked here
             (before any durable write) and again at commit, because the
             post can close while this append is in flight. *)
          Error (Validation_error (closed_post_rejection_message ~post_id closed))
        | Some post ->
          (match comment_count_cap_error_unlocked store pid with
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
               })))
    in
    (match staged with
     | Error _ as e -> e
     | Ok comment ->
        (match with_persist_lock store (fun () ->
          match append_comment store comment with
          | Error _ as e -> e
          | Ok () -> Ok (with_lock store (fun () ->
              (* Commit from a fresh read: the post can change or vanish
                 while the append is in flight; bumping the stale staged
                 copy would clobber a concurrent unrelated mutation. The
                 policy is re-checked for the same reason — it can flip
                 while the append is in flight, and commit is the
                 authoritative gate. *)
              match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
              | None -> Error (Post_not_found post_id)
              | Some { closed = Some closed; _ } ->
                Error
                  (Validation_error
                     (closed_post_rejection_message ~post_id closed))
              | Some post ->
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
                   Hashtbl.replace
                     store.posts
                     post_key
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
                   Ok { comment; audience; unresolved }))))) with
        | Error _ as e -> e
        | Ok committed ->
          (match committed with
           | Ok _ as ok -> ok
           | Error _ as e ->
             (* The durable append won but the commit lost (post deleted
                or policy flipped mid-append), so the appended row is an
                orphan on disk. Rewrite the comments snapshot to dispose
                of it — the snapshot cannot contain the orphan because
                it never reached memory. If the rewrite itself fails,
                the next successful snapshot rewrite disposes of the
                row; until then reply-count recalculation on load skips
                comments whose post is gone, so the orphan cannot
                distort counts. *)
             rewrite_comments store;
             e)))
;;

let add_comment store ~lookup ~post_id ~author ~content ?parent_id ?ttl_hours () =
  add_comment_with_audience
    store
    ~lookup
    ~post_id
    ~author
    ~content
    ?parent_id
    ?ttl_hours
    ()
  |> Result.map (fun creation -> creation.comment)
;;

let read_comments store ~post_id : (comment list, board_read_error) Result.t =
  maybe_sweep store;
  match Post_id.of_string_for_read post_id with
  | Error e -> Error e
  | Ok pid ->
    with_lock store (fun () ->
      let post_key = Post_id.to_string pid in
      let comment_ids =
        Hashtbl.find_opt store.comments_by_post post_key |> Option.value ~default:[]
      in
      let comments =
        List.filter_map (fun cid -> Hashtbl.find_opt store.comments cid) comment_ids
      in
      Ok (List.sort compare_comments_oldest_first comments))
;;

let get_comment store ~comment_id : (comment, board_error) Result.t =
  maybe_sweep store;
  match Comment_id.of_string comment_id with
  | Error e -> Error e
  | Ok cid ->
    with_lock store (fun () ->
      let comment_key = Comment_id.to_string cid in
      match Hashtbl.find_opt store.comments comment_key with
      | Some comment -> Ok comment
      | None -> Error (Comment_not_found comment_id))
;;

(** List all comments (for profile aggregation) *)
let list_comments store ?(limit = 1000) () : comment list =
  maybe_sweep store;
  with_lock store (fun () ->
    let all = Hashtbl.fold (fun _ c acc -> c :: acc) store.comments [] in
    let sorted =
      List.sort (fun (a : comment) (b : comment) -> compare_comments_oldest_first b a) all
    in
    List.filteri (fun i _ -> i < limit) sorted)
;;

(** {1 Reactions} *)

include Board_reactions

include Board_sub_boards
