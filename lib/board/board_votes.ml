include Board_core
include Board_voting

open Result.Syntax

(** {1 Stats} *)

let stats store =
  with_lock store (fun () ->
    let post_count = Hashtbl.length store.posts in
    let comment_count = Hashtbl.length store.comments in
    let now = Time_compat.now () in
    let expired_posts = Hashtbl.fold (fun _ (p : post) acc ->
      if Stdlib.Float.compare p.expires_at 0.0 > 0 && Stdlib.Float.compare p.expires_at now < 0 then acc + 1 else acc
    ) store.posts 0 in
    `Assoc [
      ("post_count", `Int post_count);
      ("comment_count", `Int comment_count);
      ("expired_pending", `Int expired_posts);
      ("last_sweep", `Float store.last_sweep);
      ("backend", `String "jsonl");
    ]
  )

let visibility_of_string = Board_votes_json.visibility_of_string
let post_of_yojson = Board_votes_json.post_of_yojson
let comment_of_yojson = Board_votes_json.comment_of_yojson

(** {1 Hearth (topic) operations} *)

module String_map = Set_util.StringMap

(** List active hearths with post counts for the requested post-kind axis. *)
let list_hearths store ?(exclude_system = false) ?(exclude_automation = false) ()
    : (string * int) list =
  with_lock store (fun () ->
    let counts =
      Hashtbl.fold
        (fun _ (p : post) acc ->
           if Board_core_classify.post_matches_filters
                ~exclude_system ~exclude_automation p
           then
             match p.hearth with
             | Some h ->
               let c = String_map.find_opt h acc |> Option.value ~default:0 in
               String_map.add h (c + 1) acc
             | None -> acc
           else acc)
        store.posts
        String_map.empty
    in
    String_map.bindings counts
    |> List.sort (fun (kl, a) (kr, b) ->
         let c = Int.compare b a in
         if c <> 0 then c else String.compare kl kr)
  )

(** Update a post's thread_id (for linking Board post → Conversation thread) *)
let set_thread_id store ~post_id ~thread_id : (unit, board_error) Result.t =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      with_lock store (fun () ->
        match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
        | None -> Error (Post_not_found post_id)
        | Some post ->
            let updated = { post with thread_id = Some thread_id } in
            Hashtbl.replace store.posts (Post_id.to_string pid) updated;
            Ok ()
      )

(** Set a post's [pinned] flag (operator-curated pin, owner-gated at the HTTP
    boundary). Persists immediately via [append_post] (like [create_post])
    rather than only marking dirty for the flusher: pinning is a low-frequency
    operator action that must survive a restart in the flush window, unlike
    [vote] (high-frequency, flusher-batched) or [set_thread_id] (in-memory). *)
let set_pinned store ~post_id ~pinned : (unit, board_error) Result.t =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
    with_persist_lock store (fun () ->
      let result =
        with_lock store (fun () ->
          match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
          | None -> Error (Post_not_found post_id)
          | Some post ->
              let now = Time_compat.now () in
              let updated = { post with pinned; updated_at = now } in
              Hashtbl.replace store.posts (Post_id.to_string pid) updated;
              invalidate_post_caches store;
              Ok (post, updated))
      in
      match result with
      | Error e -> Error e
      | Ok (previous, updated) ->
          (match append_post store updated with
           | (Posts_written _ | Posts_write_unknown _) as outcome -> finish_posts_write outcome
           | (Posts_not_written _ as outcome) ->
               with_lock store (fun () ->
                 let key = Post_id.to_string previous.id in
                 (match Hashtbl.find_opt store.posts key with
                  | Some current
                    when current.pinned = updated.pinned
                         && Stdlib.Float.equal current.updated_at updated.updated_at ->
                    Hashtbl.replace store.posts key previous;
                    invalidate_post_caches store
                  | _ -> ()));
               finish_posts_write outcome))

(** A close must state its successor decision explicitly: [Successor id]
    continues the thread, [No_successor] says there is none. There is no
    default -- a caller that names neither is refused, so a missing
    successor is never silently read as "none". *)
type close_successor =
  | No_successor
  | Successor of string

let summary_is_blank summary =
  Uutf.String.fold_utf_8
    (fun blank _ -> function
      | `Uchar uchar -> blank && Uucp.White.is_white_space uchar
      | `Malformed _ -> false)
    true
    summary
;;

(** Close a post (typed [closed] state, task-1758/#39356). Same durability
    and rollback shape as [set_pinned]: the caller ([author]/[operator]/a
    configured moderator) is checked at the HTTP/dispatch boundary, not
    here -- this function only records who closed it, once permission is
    already granted. Re-closing an already-closed post overwrites the
    previous [closed] value (last write wins; no error).

    A close must state two things explicitly, and both are enforced here so
    every surface (the author tool and the operator dashboard route) shares
    one boundary:

    - [summary] must be non-empty after trimming. A whitespace-only value is
      refused as [Validation_error]; a close with no reason is not recorded.
    - [successor] must be [Successor id] or [No_successor]. There is no
      default: a caller that names neither is refused, so a missing
      successor is never silently read as "none". A [Successor] id is
      validated against the live store: it must resolve to an existing post
      and cannot be [post_id] itself, both refused as [Validation_error]
      before anything is written -- a nonexistent or self-referential
      successor pointer would otherwise sit in posts.jsonl forever with no
      way for a reader to notice. *)
let set_closed store ~post_id ~closed_by ~successor ~summary ()
  : (unit, board_error) Result.t =
  match Post_id.of_string post_id, Agent_id.of_string closed_by with
  | Error e, _ -> Error e
  | Ok _, Error e -> Error e
  | Ok pid, Ok closed_by_id ->
    let summary = String.trim summary in
    if summary_is_blank summary then
      Error (Validation_error "close summary must not be empty")
    else
    let successor_id =
      match successor with
      | No_successor -> Ok None
      | Successor raw ->
        (match Post_id.of_string raw with
         | Ok id -> Ok (Some id)
         | Error e -> Error e)
    in
    (match successor_id with
     | Error e -> Error e
     | Ok successor_id ->
       with_persist_lock store (fun () ->
         let result =
           with_lock store (fun () ->
             match Hashtbl.find_opt store.posts (Post_id.to_string pid), successor_id with
             | None, _ -> Error (Post_not_found post_id)
             | Some _, Some sid
               when String.equal (Post_id.to_string sid) (Post_id.to_string pid) ->
               Error
                 (Validation_error
                    (Printf.sprintf "post %s cannot be its own successor" post_id))
             | Some _, Some sid
               when not (Hashtbl.mem store.posts (Post_id.to_string sid)) ->
               Error
                 (Validation_error
                    (Printf.sprintf
                       "successor_id %s does not refer to an existing post"
                       (Post_id.to_string sid)))
             | Some post, (Some _ | None) ->
               let now = Time_compat.now () in
               let closed =
                 Some { closed_by = closed_by_id; closed_at = now; successor_id; summary = Some summary }
               in
               let updated = { post with closed; updated_at = now } in
               Hashtbl.replace store.posts (Post_id.to_string pid) updated;
               invalidate_post_caches store;
               Ok (post, updated))
         in
         match result with
         | Error e -> Error e
         | Ok (previous, updated) ->
           (match append_post store updated with
            | (Posts_written _ | Posts_write_unknown _) as outcome -> finish_posts_write outcome
            | (Posts_not_written _ as outcome) ->
              with_lock store (fun () ->
                let key = Post_id.to_string previous.id in
                (match Hashtbl.find_opt store.posts key with
                 | Some current
                   when Option.is_some current.closed = Option.is_some updated.closed
                        && Stdlib.Float.equal current.updated_at updated.updated_at ->
                   Hashtbl.replace store.posts key previous;
                   invalidate_post_caches store
                 | _ -> ()));
              finish_posts_write outcome)))
;;

(** Reopen a closed post: clears [closed] back to [None]. A true no-op on an
    already-open post -- [updated_at] is left untouched and nothing is
    appended to posts.jsonl, so calling [reopen] twice does not manufacture
    a second change that a change-cursor or an Updated-sort listing would
    read as new activity (context-reviewer, review 5329575031). Permission
    is the same caller-side gate as [set_closed]. *)
let reopen store ~post_id : (unit, board_error) Result.t =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
    with_persist_lock store (fun () ->
      let result =
        with_lock store (fun () ->
          match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
          | None -> Error (Post_not_found post_id)
          | Some post when Option.is_none post.closed -> Ok None
          | Some post ->
            let now = Time_compat.now () in
            let updated = { post with closed = None; updated_at = now } in
            Hashtbl.replace store.posts (Post_id.to_string pid) updated;
            invalidate_post_caches store;
            Ok (Some (post, updated)))
      in
      match result with
      | Error e -> Error e
      | Ok None -> Ok () (* already open: no write, no updated_at bump *)
      | Ok (Some (previous, updated)) ->
        (match append_post store updated with
         | (Posts_written _ | Posts_write_unknown _) as outcome -> finish_posts_write outcome
         | (Posts_not_written _ as outcome) ->
           with_lock store (fun () ->
             let key = Post_id.to_string previous.id in
             (match Hashtbl.find_opt store.posts key with
              | Some current
                when Option.is_none current.closed
                     && Stdlib.Float.equal current.updated_at updated.updated_at ->
                Hashtbl.replace store.posts key previous;
                invalidate_post_caches store
              | _ -> ()));
           finish_posts_write outcome))
;;

let reactions_jsonl_snapshot store =
  let buf = Buffer.create 4096 in
  Hashtbl.iter
    (fun _ (reaction : reaction) ->
       Buffer.add_string buf (Yojson.Safe.to_string (reaction_to_yojson reaction));
       Buffer.add_char buf '\n')
    store.reactions;
  Buffer.contents buf

module Snapshot_batch = Board_snapshot_batch

(* Snapshot rendering updates the row caches, so callers hold the state lock. *)
let capture_snapshot_batch store selection =
  Snapshot_batch.capture selection
    ~posts:(fun () -> capture_posts_snapshot store)
    ~comments:(fun () -> capture_comments_snapshot store)
    ~votes:(fun () -> vote_log_jsonl store)
    ~reactions:(fun () -> reactions_jsonl_snapshot store)
;;

let write_snapshot store = function
  | Snapshot_batch.Posts_payload snapshot -> finish_posts_write (save_posts_snapshot store snapshot)
  | Snapshot_batch.Comments_payload content -> save_comments_snapshot store content
  | Snapshot_batch.Votes_payload content -> save_vote_log_jsonl store content
  | Snapshot_batch.Reactions_payload content -> Board_core_persist.save_reactions_jsonl_result store content
;;

(* Re-mark everything dirty after a failed snapshot write, so the next flush
   rewrites the file instead of skipping an empty queue — the missing half of
   a log-and-continue failure (#26168). Callers hold the store lock. *)
let remark_all_posts_dirty store =
  store.dirty_posts <- true;
  Hashtbl.iter (fun key _ -> Hashtbl.replace store.dirty_post_ids key ()) store.posts
;;

let remark_all_comments_dirty store =
  store.dirty_comments <- true;
  Hashtbl.iter
    (fun key _ -> Hashtbl.replace store.dirty_comment_ids key ())
    store.comments
;;

(* Called under the state lock; never clear concurrent edits after capture. *)
let remark_snapshot_retry store = function
  | Snapshot_batch.Retry_posts -> remark_all_posts_dirty store
  | Snapshot_batch.Retry_comments -> remark_all_comments_dirty store
;;

type deletion_outcome =
  | Durable_deletion
  | Deletion_persistence_pending of string

let delete_post store ~post_id : (deletion_outcome, board_error) Result.t =
  (* Deleting rewrites every snapshot below after the post has left memory, so
     each file it rewrites must have loaded fully first (#38595). *)
  with_persist_lock store (fun () ->
  let* () = require_posts_source_readable store in
  let* () = require_comments_source_readable store in
  let* () = require_persisted_snapshot_readable store.votes_load_result in
  let* () = require_persisted_snapshot_readable store.reactions_load_result in
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
    let snapshot =
      with_lock store (fun () ->
      let post_key = Post_id.to_string pid in
      match Hashtbl.find_opt store.posts post_key with
      | None -> Error (Post_not_found post_id)
      | Some post ->
        store.snapshot_retry <- Deletion_pending;
        let comment_ids =
          Hashtbl.fold
            (fun key (c : comment) acc ->
               if String.equal (Post_id.to_string c.post_id) post_key then key :: acc else acc)
            store.comments
            []
        in
        unindex_post_origin store post;
        unindex_hot_post store post;
        Hashtbl.remove store.posts post_key;
        Hashtbl.remove store.comments_by_post post_key;
        List.iter (fun comment_key -> Hashtbl.remove store.comments comment_key) comment_ids;
        let vote_keys =
          Hashtbl.fold
            (fun key _ acc ->
               match Board_vote_key.of_string key with
               | Some vote ->
                 let target_id = Board_vote_key.target_id vote in
                 (match Board_vote_key.target_kind vote with
                  | Board_vote_key.Post when String.equal target_id post_key ->
                    key :: acc
                  | Board_vote_key.Comment
                    when List.exists (String.equal target_id) comment_ids ->
                    key :: acc
                  | Board_vote_key.Post | Board_vote_key.Comment -> acc)
               | None -> acc)
            store.vote_log
            []
        in
        let reaction_keys =
          Hashtbl.fold
            (fun key (reaction : reaction) acc ->
               if
                 ((=) reaction.target_type Reaction_post
                  && String.equal reaction.target_id post_key)
                 || ((=) reaction.target_type Reaction_comment
                     && List.exists (String.equal reaction.target_id) comment_ids)
               then key :: acc
               else acc)
            store.reactions
            []
        in
        List.iter (fun key -> Hashtbl.remove store.vote_log key) vote_keys;
        List.iter (fun key -> Hashtbl.remove store.reactions key) reaction_keys;
        store.post_count := max 0 (!(store.post_count) - 1);
        invalidate_post_caches store;
        invalidate_comment_caches store;
        store.dirty_posts <- false;
        store.dirty_comments <- false;
        Hashtbl.clear store.dirty_post_ids;
        Hashtbl.clear store.dirty_comment_ids;
        store.last_flush <- Time_compat.now ();
        Ok (capture_snapshot_batch store Snapshot_batch.for_delete))
    in
    (match snapshot with
     | Error _ as e -> e
     | Ok batch ->
       let outcome =
         Snapshot_batch.persist batch ~write:(write_snapshot store)
       in
       (* The snapshot cleared dirty flags while holding the state lock.
          Preserve failed writes for a later flush. *)
       with_lock store (fun () ->
         let retries = Snapshot_batch.retries outcome in
         List.iter (remark_snapshot_retry store) retries;
         match retries with
         | [] -> store.snapshot_retry <- Independent_snapshots
         | _ :: _ -> ());
       Snapshot_batch.finish_settlement outcome;
       let failures =
         List.map show_board_error (Snapshot_batch.errors outcome)
       in
       match failures with
       | [] -> Ok Durable_deletion
       | _ :: _ -> Ok (Deletion_persistence_pending (String.concat "; " failures))))

(** {1 Store lifecycle and flushing} *)

let global = Board_store_lifecycle.global
let reset_global_for_test = Board_store_lifecycle.reset_global_for_test

(** Flush any dirty state to disk. Call on shutdown to prevent data loss.

    RFC-0091 (board persistence path unification): mutation/vote flushes
    write a full snapshot instead of replaying
    the dirty list through [append_post]/[append_comment]. The previous
    [List.iter append_post posts] grew [board_posts.jsonl] by one line per
    vote/mutation per post, sharing the same .id, producing the dup vector
    that motivated the RFC. The snapshot path was already canonical for
    restart-load ([Board_votes_json.load_persisted_posts]), so promoting it to the
    flush-write path makes [board_posts.jsonl] a true snapshot file with
    one line per id and atomic rewrite semantics. *)
let flush_dirty store =
  with_persist_lock store (fun () ->
  let batch =
    with_lock store (fun () ->
      let selection =
        match store.snapshot_retry with
        | Deletion_pending -> Snapshot_batch.for_delete
        | Independent_snapshots -> Snapshot_batch.for_flush
          ~dirty_posts:store.dirty_posts
          ~dirty_comments:store.dirty_comments
          ~votes_readable:(Result.is_ok store.votes_load_result)
          ~reactions_readable:(Result.is_ok store.reactions_load_result)
      in
      let batch = capture_snapshot_batch store selection in
      Hashtbl.clear store.dirty_post_ids;
      Hashtbl.clear store.dirty_comment_ids;
      store.dirty_posts <- false;
      store.dirty_comments <- false;
      store.last_flush <- Time_compat.now ();
      batch)
  in
  (* Flush requeues each failed write before attempting the next. Captured
     empty snapshots still write, and later edits keep their own dirty flags. *)
  let outcome = Snapshot_batch.persist batch ~write:(fun content ->
       match write_snapshot store content with
       | Ok () -> Ok ()
       | Error _ as error ->
         with_lock store (fun () ->
           remark_snapshot_retry store (Snapshot_batch.retry_for_kind (Snapshot_batch.kind_of_payload content)));
         error) in
  (* A proven nonwrite may carry reserved descriptor cleanup as typed data,
     bypassing the callback's normal returned-error retry arm. *)
  with_lock store (fun () ->
    let retries = Snapshot_batch.retries outcome in
    List.iter (remark_snapshot_retry store) retries;
    match retries with
    | [] -> store.snapshot_retry <- Independent_snapshots
    | _ :: _ -> ());
  Snapshot_batch.finish_settlement outcome)


(** {1 Karma & Flair - Reddit-style} *)

(** Scoring contract: returns the karma delta for a vote direction.
    Upvotes earn +1 karma; downvotes do not deduct karma (delta = 0).
    Callers that want to replay or rebuild the ledger must use this
    function as the single source of truth for karma scoring. *)
let karma_score_for_direction = function
  | Up -> 1
  | Down -> 0

(** A single attributed karma event.  One event is generated per upvote
    received by an agent.  Downvotes do not generate karma events
    (scoring rule: [Up] = +1, [Down] = 0). *)
type karma_event = {
  recipient : string;
  (** Agent who earned the karma — author of the upvoted post or comment. *)
  voter : string;
  (** Agent who cast the upvote. *)
  target_kind : Board_vote_key.target_kind;
  (** The upvoted content's kind, read off the vote key. *)
  target_id : string;
  (** Identifier of the upvoted post or comment. *)
  delta : int;
  (** Karma delta.  Always [+1] per upvote under the current scoring
      contract.  Stored explicitly so future rule changes are backward
      compatible — older events keep their original delta value. *)
  ts : float;
  (** Unix timestamp at which the upvote was cast (seconds since epoch). *)
}

let karma_event_of_vote store key (direction, ts) =
  let delta = karma_score_for_direction direction in
  if delta = 0 then None
  else
    match Board_vote_key.of_string key with
    | None -> None
    | Some vote ->
        let target_id = Board_vote_key.target_id vote in
        let voter = Board_vote_key.voter vote |> Agent_id.to_string in
        let target_kind = Board_vote_key.target_kind vote in
        let recipient_opt =
          match target_kind with
          | Board_vote_key.Post ->
            (match Hashtbl.find_opt store.posts target_id with
             | Some (p : post) -> Some (Agent_id.to_string p.author)
             | None -> None)
          | Board_vote_key.Comment ->
            (match Hashtbl.find_opt store.comments target_id with
             | Some (c : comment) -> Some (Agent_id.to_string c.author)
             | None -> None)
        in
        match recipient_opt with
        | None -> None
        | Some recipient when String.equal recipient voter ->
            (* Content score still records the vote, but karma is
               peer recognition; self-upvotes do not mint reputation. *)
            None
        | Some recipient ->
            Some { recipient; voter; target_kind; target_id; delta; ts }

(** Rebuild the karma ledger from the in-memory vote log and
    post/comment author tables.

    Contract:
    - Only [Up] votes generate karma events (scoring rule via
      {!karma_score_for_direction}).
    - Events are sorted ascending by [ts] (oldest first) so callers
      can replay them in order.
    - Author lookup is done against the live in-memory store; entries
      whose post/comment has been deleted are silently dropped (the
      vote remains in the log but the content is gone).
    - The function holds the store lock for the duration of the read
      so the snapshot is consistent. *)
let build_karma_ledger store =
  with_lock store (fun () ->
    Hashtbl.fold
      (fun key (direction, ts) acc ->
         match karma_event_of_vote store key (direction, ts) with
         | None -> acc
         | Some event -> event :: acc)
      store.vote_log [])
  |> List.sort (fun a b -> Float.compare a.ts b.ts)

(** Aggregate karma totals from a ledger.

    Returns [(recipient, total_karma)] pairs sorted descending by
    total so the highest-karma agents appear first.  Suitable for
    populating the karma leaderboard without re-reading the store. *)
let totals_of_karma_ledger events =
  let by_recipient =
    List.fold_left
      (fun acc (e : karma_event) ->
         let prev = String_map.find_opt e.recipient acc |> Option.value ~default:0 in
         String_map.add e.recipient (prev + e.delta) acc)
      String_map.empty
      events
  in
  String_map.bindings by_recipient
  |> List.sort (fun (kl, a) (kr, b) ->
       let c = Int.compare b a in
       if c <> 0 then c else String.compare kl kr)

(** JSON serialiser for a single karma event.

    Wire format (stable):
    {v
      { "recipient": "<agent>",
        "voter":     "<agent>",
        "target_kind": "post" | "comment",
        "target_id": "<id>",
        "delta": 1,
        "ts": 1234567890.0,
        "ts_iso": "YYYY-MM-DDTHH:MM:SSZ" }
    v} *)
let karma_event_to_yojson (e : karma_event) : Yojson.Safe.t =
  let ts_iso = Masc_domain.iso8601_of_unix_seconds e.ts in
  `Assoc [
    ("recipient",   `String e.recipient);
    ("voter",       `String e.voter);
    ("target_kind", `String (Board_vote_key.target_kind_to_string e.target_kind));
    ("target_id",   `String e.target_id);
    ("delta",       `Int    e.delta);
    ("ts",          `Float  e.ts);
    ("ts_iso",      `String ts_iso);
  ]

(** Get karma for all agents (cached).

    Cache check / rebuild / write are all performed inside one
    [with_lock] block.  Previously the read at [store.karma_cache]
    and the write to it lived outside [with_lock] while
    [Board_core.invalidate_*_caches] (callers always hold the lock)
    cleared the field under lock — so two fibers could both observe
    [None] and both rebuild, and an invalidation occurring between an
    unlocked read of a stale [Some _] and a downstream consumer was
    silently lost.  Hashtbl iteration / fold / List.sort are pure CPU
    with no fiber yields, so holding the Eio mutex during the rebuild
    is safe. *)
let get_karma_rollup store =
  with_lock store (fun () ->
    match store.karma_cache with
    | Some cached -> cached
    | None ->
      let by_recipient, by_post = Hashtbl.fold (fun key vote (totals, index) ->
        match karma_event_of_vote store key vote with
        | None -> totals, index
        | Some (event : karma_event) ->
          let previous = match String_map.find_opt event.recipient totals with None -> 0 | Some n -> n in
          let totals = String_map.add event.recipient (previous + event.delta) totals in
          let post_id = match event.target_kind with
            | Board_vote_key.Post -> Some event.target_id
            | Board_vote_key.Comment ->
              Option.map (fun (comment : comment) -> Post_id.to_string comment.post_id)
                (Hashtbl.find_opt store.comments event.target_id) in
          match post_id with
          | None -> totals, index
          | Some post_id ->
            let posts = match String_map.find_opt event.recipient index with None -> String_map.empty | Some posts -> posts in
            let previous = match String_map.find_opt post_id posts with None -> 0 | Some n -> n in
            totals, String_map.add event.recipient (String_map.add post_id (previous + event.delta) posts) index)
        store.vote_log (String_map.empty, String_map.empty) in
      let totals = String_map.bindings by_recipient |> List.sort (fun (a, x) (b, y) ->
        let c = Int.compare y x in if c = 0 then String.compare a b else c) in
      let index = String_map.bindings by_post |> List.map (fun (author, posts) -> author, String_map.bindings posts) in
      let result = totals, index in
      store.karma_cache <- Some result;
      result)

let get_all_karma store = fst (get_karma_rollup store)
let get_karma_by_post store = snd (get_karma_rollup store)

(** Calculate karma (total peer upvotes) for an agent *)
let get_agent_karma store ~agent_name =
  get_all_karma store
  |> List.assoc_opt agent_name
  |> Option.value ~default:0

(** Available flairs *)
let available_flairs = [
  ("insight", "💡", "Insight");
  ("question", "❓", "Question");
  ("discussion", "💬", "Discussion");
  ("announcement", "📢", "Announcement");
  ("bug", "🐛", "Bug Report");
  ("idea", "💭", "Idea");
  ("meta", "🔧", "Meta");
]

(* Flair tag pattern — pure literal, hoist out of per-post extraction. *)
let flair_tag_re = Re.Pcre.re {|\[flair:([a-z]+)\]|} |> Re.compile

(** Extract flair from content (format: [flair:name] at start) *)
let extract_flair content =
  match Re.exec_opt flair_tag_re content with
  | Some g ->
    let flair_name = Re.Group.get g 1 in
    (match List.find_opt (fun (name, _, _) -> String.equal name flair_name) available_flairs with
    | Some f -> Some f
    | None -> None)
  | None -> None

(** Get flair info as JSON *)
let flair_to_yojson (name, emoji, label) =
  `Assoc [("name", `String name); ("emoji", `String emoji); ("label", `String label)]

(** Enhanced post_to_yojson with karma *)
let post_to_yojson_with_karma (p : post) ~author_karma : Yojson.Safe.t =
  let flair = extract_flair p.body in
  let flair_json = match flair with Some f -> flair_to_yojson f | None -> `Null in
  `Assoc ([
    ("id", `String (Post_id.to_string p.id));
    ("author", `String (Agent_id.to_string p.author));
    ("author_karma", `Int author_karma);
    ("title", `String p.title);
    ("body", `String p.body);
    ("post_kind", `String (post_kind_to_string p.post_kind));
    ("flair", flair_json);
    ("visibility", `String (visibility_to_string p.visibility));
    ("created_at", `Float p.created_at);
    ("updated_at", `Float p.updated_at);
    ("expires_at", `Float p.expires_at);
    ("votes_up", `Int p.votes_up);
    ("votes_down", `Int p.votes_down);
    ("score", `Int (p.votes_up - p.votes_down));
    ("reply_count", `Int p.reply_count);
    ("pinned", `Bool p.pinned);
  ] @ (match p.audience with Some audience -> [("audience", Board_audience.to_yojson audience)] | None -> [])
    @ (match p.hearth with Some h -> [("hearth", `String h)] | None -> [])
    @ (match p.thread_id with Some t -> [("thread_id", `String t)] | None -> [])
    (* RFC-0233 §7: the dashboard board serializer ([board_post_dashboard_json])
       funnels every board list/detail route through this function, so emitting
       [origin] here exposes the originating-turn provenance on every
       dashboard-facing post in one place (no per-route N-of-M). Same encoder as
       [post_to_yojson] so the wire shape is identical. *)
    @ (match p.origin with Some o -> [("origin", post_origin_to_yojson o)] | None -> [])
    (* task-1758/#39356 completion criterion 4: dashboard/TUI reads must show
       closed state and successor, same as {!post_to_yojson} already does --
       this hand-rolled encoder does not derive from that one, so without
       this line a closed post would look open on the dashboard. *)
    @ (match p.closed with Some c -> [("closed", post_close_state_to_yojson c)] | None -> [])
    @ (match post_classification_reason p with
       | Some reason -> [("classification_reason", `String reason)]
       | None -> [])
    @ (match p.meta_json with Some meta -> [("meta", meta)] | None -> []))
