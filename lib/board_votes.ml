include Board_core

let vote_direction_to_string = function Up -> "up" | Down -> "down"

(* Issue #8506: Variant SSOT for vote_direction. Adding a constructor
   forces [vote_direction_to_string] exhaustiveness AND extends
   [valid_vote_direction_strings]; the schema in [tool_shard.ml]
   mirrors this list (cycle-aware, sync test). Previously
   server_bootstrap_loops.ml re-implemented the same match inline 4
   times — those call sites now use this helper. *)
let all_vote_directions = [ Up; Down ]
let valid_vote_direction_strings =
  List.map vote_direction_to_string all_vote_directions

(* Sound partial parser — case-insensitive, trims whitespace, accepts
   empty as default Up for back-compat with [tool_board.ml] which
   defaults to "up" when the field is missing. *)
let vote_direction_of_string_opt raw =
  match String.trim (String.lowercase_ascii raw) with
  | "up" | "" -> Some Up
  | "down" -> Some Down
  | _ -> None

let vote_log_path () =
  let base = board_base_path () in
  Filename.concat base ".masc/board_votes.jsonl"

let append_vote_log ~target ~voter ~direction =
  try
    ensure_masc_dir ();
    let path = vote_log_path () in
    let json = `Assoc [
      ("target", `String target);
      ("voter", `String voter);
      ("direction", `String (vote_direction_to_string direction));
      ("ts", `Float (Time_compat.now ()));
    ] in
    Fs_compat.append_file path (Yojson.Safe.to_string json ^ "\n");
    rotate_if_needed path
  with Sys_error msg -> Log.BoardLog.error "persist error (append_vote_log): %s" msg

let rewrite_vote_log store =
  try
    ensure_masc_dir ();
    let path = vote_log_path () in
    let buf = Buffer.create 4096 in
    Hashtbl.iter
      (fun target direction ->
        let voter =
          match String.rindex_opt target ':' with
          | Some idx when idx + 1 < String.length target ->
              String.sub target (idx + 1) (String.length target - idx - 1)
          | _ -> ""
        in
        let json =
          `Assoc
            [
              ("target", `String target);
              ("voter", `String voter);
              ("direction", `String (vote_direction_to_string direction));
              ("ts", `Float (Time_compat.now ()));
            ]
        in
        Buffer.add_string buf (Yojson.Safe.to_string json ^ "\n"))
      store.vote_log;
    (match Fs_compat.save_file_atomic path (Buffer.contents buf) with
     | Ok () -> ()
     | Error msg -> Log.BoardLog.error "persist error (rewrite_vote_log): %s" msg)
  with Sys_error msg -> Log.BoardLog.error "persist error (rewrite_vote_log): %s" msg

(* [vote_outcome] carries the information needed to run the post-lock
   [Agent_economy.earn] call.  [earn_upvote_for] is [Some author] only
   on the fresh-upvote path — a vote flip does not earn credits
   (prevents down/up alternation abuse), and a downvote does not earn
   at all. *)
type vote_outcome = {
  delta : int;
  earn_upvote_for : string option;
}

let vote store ~voter ~post_id ~direction : (int, board_error) result =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok _ ->
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      let board_result : (vote_outcome, board_error) result =
        with_lock store (fun () ->
          match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
          | None -> Error (Post_not_found post_id)
          | Some post ->
              let vote_key = "post:" ^ Post_id.to_string pid ^ ":" ^ voter in
              let now = Time_compat.now () in
              match Hashtbl.find_opt store.vote_log vote_key with
              | Some prev when prev = direction ->
                  Error (Already_voted (Printf.sprintf "%s already voted %s on %s"
                    voter (vote_direction_to_string direction) post_id))
              | Some _opposite ->
                  let flipped = match direction with
                    | Up -> { post with votes_up = post.votes_up + 1;
                                        votes_down = max 0 (post.votes_down - 1);
                                        updated_at = now }
                    | Down -> { post with votes_down = post.votes_down + 1;
                                          votes_up = max 0 (post.votes_up - 1);
                                          updated_at = now }
                  in
                  Hashtbl.replace store.posts (Post_id.to_string pid) flipped;
                  Hashtbl.replace store.vote_log vote_key direction;
                  store.dirty_posts <- true;  (* Deferred flush *)
                  invalidate_post_caches store;
                  append_vote_log ~target:vote_key ~voter ~direction;
                  (* Record vote for Thompson Sampling feedback *)
                  let author_name = Agent_id.to_string post.author in
                  let vote_dir = match direction with Up -> `Up | Down -> `Down in
                  Thompson_sampling.record_vote ~agent_name:author_name ~direction:vote_dir;
                  (* No economy earn on flip: prevents down/up alternation abuse *)
                  Ok { delta = flipped.votes_up - flipped.votes_down;
                       earn_upvote_for = None }
              | None ->
                  let updated = match direction with
                    | Up -> { post with votes_up = post.votes_up + 1; updated_at = now }
                    | Down -> { post with votes_down = post.votes_down + 1; updated_at = now }
                  in
                  Hashtbl.replace store.posts (Post_id.to_string pid) updated;
                  Hashtbl.replace store.vote_log vote_key direction;
                  store.dirty_posts <- true;  (* Deferred flush *)
                  invalidate_post_caches store;
                  append_vote_log ~target:vote_key ~voter ~direction;
                  (* Record vote for Thompson Sampling feedback *)
                  let author_name = Agent_id.to_string post.author in
                  let vote_dir = match direction with Up -> `Up | Down -> `Down in
                  Thompson_sampling.record_vote ~agent_name:author_name ~direction:vote_dir;
                  let earn =
                    if direction = Up then Some author_name else None
                  in
                  Ok { delta = updated.votes_up - updated.votes_down;
                       earn_upvote_for = earn })
      in
      (* Agent Economy: earn credits for an upvote received.  Moved
         OUTSIDE the store lock — [Agent_economy.earn] writes its own
         ledger file on an unrelated path and modifies no board state,
         so holding [store.mutex] across its disk I/O was gratuitous
         contention with every other reader/writer. *)
      (match board_result with
       | Ok { delta; earn_upvote_for = Some author_name } ->
           (match Agent_economy.earn
              ~base_path:(board_base_path ()) ~agent_name:author_name
              ~kind:Earn_upvote ~reason:"upvote on post" () with
            | Ok _ -> ()
            | Error e ->
                Log.Board.warn "board_votes: economy earn failed for %s: %s" author_name e);
           Ok delta
       | Ok { delta; earn_upvote_for = None } -> Ok delta
       | Error _ as e -> e)

(** Vote on a comment *)
let vote_comment store ~voter ~comment_id ~direction : (int, board_error) result =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok _ ->
  match Comment_id.of_string comment_id with
  | Error e -> Error e
  | Ok cid ->
      with_lock store (fun () ->
        match Hashtbl.find_opt store.comments (Comment_id.to_string cid) with
        | None -> Error (Comment_not_found comment_id)
        | Some cmt ->
            let vote_key = "comment:" ^ Comment_id.to_string cid ^ ":" ^ voter in
            match Hashtbl.find_opt store.vote_log vote_key with
            | Some prev when prev = direction ->
                Error (Already_voted (Printf.sprintf "%s already voted %s on comment %s"
                  voter (vote_direction_to_string direction) comment_id))
            | Some _opposite ->
                let flipped = match direction with
                  | Up -> { cmt with votes_up = cmt.votes_up + 1;
                                     votes_down = max 0 (cmt.votes_down - 1) }
                  | Down -> { cmt with votes_down = cmt.votes_down + 1;
                                       votes_up = max 0 (cmt.votes_up - 1) }
                in
                Hashtbl.replace store.comments (Comment_id.to_string cid) flipped;
                Hashtbl.replace store.vote_log vote_key direction;
                store.dirty_comments <- true;  (* Deferred flush *)
                invalidate_comment_caches store;
                append_vote_log ~target:vote_key ~voter ~direction;
                (* Record vote for Thompson Sampling feedback *)
                let author_name = Agent_id.to_string cmt.author in
                let vote_dir = match direction with Up -> `Up | Down -> `Down in
                Thompson_sampling.record_vote ~agent_name:author_name ~direction:vote_dir;
                Ok (flipped.votes_up - flipped.votes_down)
            | None ->
                let updated = match direction with
                  | Up -> { cmt with votes_up = cmt.votes_up + 1 }
                  | Down -> { cmt with votes_down = cmt.votes_down + 1 }
                in
                Hashtbl.replace store.comments (Comment_id.to_string cid) updated;
                Hashtbl.replace store.vote_log vote_key direction;
                store.dirty_comments <- true;  (* Deferred flush *)
                invalidate_comment_caches store;
                append_vote_log ~target:vote_key ~voter ~direction;
                (* Record vote for Thompson Sampling feedback *)
                let author_name = Agent_id.to_string cmt.author in
                let vote_dir = match direction with Up -> `Up | Down -> `Down in
                Thompson_sampling.record_vote ~agent_name:author_name ~direction:vote_dir;
                Ok (updated.votes_up - updated.votes_down)
      )

(** {1 Stats} *)

let stats store =
  with_lock store (fun () ->
    let post_count = Hashtbl.length store.posts in
    let comment_count = Hashtbl.length store.comments in
    let now = Time_compat.now () in
    let expired_posts = Hashtbl.fold (fun _ (p : post) acc ->
      if p.expires_at > 0.0 && p.expires_at < now then acc + 1 else acc
    ) store.posts 0 in
    `Assoc [
      ("post_count", `Int post_count);
      ("comment_count", `Int comment_count);
      ("expired_pending", `Int expired_posts);
      ("last_sweep", `Float store.last_sweep);
      ("backend", `String "jsonl");
    ]
  )

let visibility_of_string = Board_core_classify.visibility_of_string

let post_of_yojson (json : Yojson.Safe.t) : post option =
  match
    Safe_ops.json_string_opt "id" json,
    Safe_ops.json_string_opt "author" json,
    Safe_ops.json_string_opt "content" json,
    Safe_ops.json_string_opt "visibility" json,
    Safe_ops.json_float_opt "created_at" json,
    Safe_ops.json_float_opt "expires_at" json
  with
  | Some id_str, Some author_str, Some content, Some vis_str,
    Some created_at, Some expires_at ->
    let title_opt = Safe_ops.json_string_opt "title" json in
    let body_opt = Safe_ops.json_string_opt "body" json in
    (* Backward compat: default updated_at to created_at if missing *)
    let updated_at =
      Safe_ops.json_float_opt "updated_at" json
      |> Option.value ~default:created_at
    in
    let votes_up = Safe_ops.json_int ~default:0 "votes_up" json in
    let votes_down = Safe_ops.json_int ~default:0 "votes_down" json in
    let reply_count = Safe_ops.json_int ~default:0 "reply_count" json in
    let hearth = Safe_ops.json_string_opt "hearth" json in
    let thread_id = Safe_ops.json_string_opt "thread_id" json in
    let post_kind_opt =
      match Safe_ops.json_string_opt "post_kind" json with
      | Some raw -> post_kind_of_string raw
      | None -> None
    in
    let meta_json =
      match Safe_ops.json_member_opt "meta" json with
      | Some (`Assoc _ as meta) -> Some meta
      | Some _ | None ->
        (match Safe_ops.json_string_opt "meta_json" json with
         | Some raw -> (try Some (Yojson.Safe.from_string raw) with Yojson.Json_error _ -> None)
         | None -> None)
    in
    (match Post_id.of_string id_str, Agent_id.of_string author_str, visibility_of_string vis_str with
    | Ok id, Ok author, Some visibility ->
        let resolved_kind =
          match post_kind_opt with
          | Some kind -> kind
          | None ->
              legacy_migrate_post_kind
                ~author:author_str
                ~meta_json
                ~visibility
                ~expires_at
                ~hearth
        in
        let title, body, post_kind, meta_json =
          normalize_post_payload ~content ?title:title_opt ?body:body_opt
            ~post_kind:resolved_kind ?meta_json ()
        in
        Some {
          id;
          author;
          title;
          body;
          content = body;
          post_kind;
          meta_json;
          visibility;
          created_at;
          updated_at;
          expires_at;
          votes_up;
          votes_down;
          reply_count;
          hearth;
          thread_id;
        }
    | _ -> None)
  | _ -> None

let comment_of_yojson (json : Yojson.Safe.t) : comment option =
  match
    Safe_ops.json_string_opt "id" json,
    Safe_ops.json_string_opt "post_id" json,
    Safe_ops.json_string_opt "author" json,
    Safe_ops.json_string_opt "content" json,
    Safe_ops.json_float_opt "created_at" json,
    Safe_ops.json_float_opt "expires_at" json
  with
  | Some id_str, Some post_id_str, Some author_str, Some content,
    Some created_at, Some expires_at ->
    let parent_id_opt = Safe_ops.json_string_opt "parent_id" json in
    let votes_up = Safe_ops.json_int ~default:0 "votes_up" json in
    let votes_down = Safe_ops.json_int ~default:0 "votes_down" json in
    (match Comment_id.of_string id_str, Post_id.of_string post_id_str, Agent_id.of_string author_str with
    | Ok id, Ok post_id, Ok author ->
        let parent_id = match parent_id_opt with
          | Some s -> (match Comment_id.of_string s with Ok cid -> Some cid | _ -> None)
          | None -> None
        in
        Some { id; post_id; parent_id; author; content; created_at; expires_at; votes_up; votes_down }
    | _ -> None)
  | _ -> None

let load_persisted_posts store =
  let path = persist_path () in
  if Fs_compat.file_exists path then begin
    try
      let now = Time_compat.now () in
      let loaded = ref 0 in
      let lines = Fs_compat.load_jsonl path in
      List.iter (fun json ->
        match post_of_yojson json with
        | Some p when p.expires_at = 0.0 || p.expires_at > now ->
            Hashtbl.replace store.posts (Post_id.to_string p.id) p;
            incr loaded
        | _ -> ()
      ) lines;
      store.post_count := Hashtbl.length store.posts;
      if !loaded > 0 then
        Log.BoardLog.info "loaded %d posts from %s" !loaded path
      else
        Log.BoardLog.debug "loaded 0 posts from %s" path
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Log.BoardLog.error "load posts failed: %s" (Printexc.to_string e)
  end

let load_persisted_comments store =
  let path = comments_path () in
  if Fs_compat.file_exists path then begin
    try
      let now = Time_compat.now () in
      let loaded = ref 0 in
      let lines = Fs_compat.load_jsonl path in
      List.iter (fun json ->
        match comment_of_yojson json with
        | Some c when c.expires_at = 0.0 || c.expires_at > now ->
            let cid = Comment_id.to_string c.id in
            Hashtbl.replace store.comments cid c;
            (* Build comments_by_post index *)
            let post_key = Post_id.to_string c.post_id in
            let existing = Hashtbl.find_opt store.comments_by_post post_key |> Option.value ~default:[] in
            Hashtbl.replace store.comments_by_post post_key (cid :: existing);
            incr loaded
        | _ -> ()
      ) lines;
      if !loaded > 0 then
        Log.BoardLog.info "loaded %d comments from %s" !loaded path
      else
        Log.BoardLog.debug "loaded 0 comments from %s" path
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Log.BoardLog.error "load comments failed: %s" (Printexc.to_string e)
  end

(** Recalculate reply_count for all posts based on actual comments.
    This ensures data consistency after loading from disk. *)
let recalculate_reply_counts store =
  (* First, reset all reply_counts to 0 *)
  Hashtbl.iter (fun key (p : post) ->
    Hashtbl.replace store.posts key { p with reply_count = 0 }
  ) store.posts;
  (* Then, count actual comments per post *)
  Hashtbl.iter (fun _ (c : comment) ->
    let post_key = Post_id.to_string c.post_id in
    match Hashtbl.find_opt store.posts post_key with
    | Some p ->
        Hashtbl.replace store.posts post_key { p with reply_count = p.reply_count + 1 }
    | None -> ()
  ) store.comments;
  let total = Hashtbl.fold (fun _ (p : post) acc -> acc + p.reply_count) store.posts 0 in
  Log.BoardLog.debug "recalculated reply_counts: %d total comments across posts" total

let load_persisted_votes store =
  let path = vote_log_path () in
  if Fs_compat.file_exists path then begin
    try
      let loaded = ref 0 in
      let lines = Fs_compat.load_jsonl path in
      List.iter (fun json ->
        match Safe_ops.json_string_opt "target" json,
              Safe_ops.json_string_opt "direction" json with
        | Some target, Some dir_str ->
          let direction = if dir_str = "down" then Down else Up in
          Hashtbl.replace store.vote_log target direction;
          incr loaded
        | _ -> ()
      ) lines;
      if !loaded > 0 then
        Log.BoardLog.info "loaded %d vote entries from %s" !loaded path
      else
        Log.BoardLog.debug "loaded 0 vote entries from %s" path
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Log.BoardLog.error "load votes failed: %s" (Printexc.to_string e)
  end

(** {1 Hearth (topic) operations} *)

(** List active hearths with post counts *)
let list_hearths store : (string * int) list =
  with_lock store (fun () ->
    let counts = Hashtbl.create 16 in
    Hashtbl.iter (fun _ (p : post) ->
      match p.hearth with
      | Some h ->
          let c = Hashtbl.find_opt counts h |> Option.value ~default:0 in
          Hashtbl.replace counts h (c + 1)
      | None -> ()
    ) store.posts;
    Hashtbl.fold (fun k v acc -> (k, v) :: acc) counts []
    |> List.sort (fun (_, a) (_, b) -> compare b a)
  )

(** Update a post's thread_id (for linking Board post → Conversation thread) *)
let set_thread_id store ~post_id ~thread_id : (unit, board_error) result =
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

let delete_post store ~post_id : (unit, board_error) result =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      with_lock store (fun () ->
        let post_key = Post_id.to_string pid in
        match Hashtbl.find_opt store.posts post_key with
        | None -> Error (Post_not_found post_id)
        | Some _ ->
            let comment_ids =
              Hashtbl.fold
                (fun key (c : comment) acc ->
                  if Post_id.to_string c.post_id = post_key then key :: acc else acc)
                store.comments []
            in
            Hashtbl.remove store.posts post_key;
            Hashtbl.remove store.comments_by_post post_key;
            List.iter (fun comment_key -> Hashtbl.remove store.comments comment_key) comment_ids;
            let vote_keys =
              Hashtbl.fold
                (fun key _ acc ->
                  if String.starts_with ~prefix:("post:" ^ post_key ^ ":") key
                     || List.exists
                          (fun comment_key ->
                            String.starts_with ~prefix:("comment:" ^ comment_key ^ ":") key)
                          comment_ids
                  then key :: acc
                  else acc)
                store.vote_log []
            in
            List.iter (fun key -> Hashtbl.remove store.vote_log key) vote_keys;
            store.post_count := max 0 (!(store.post_count) - 1);
            invalidate_post_caches store;
            invalidate_comment_caches store;
            rewrite_posts store;
            rewrite_comments store;
            rewrite_vote_log store;
            store.dirty_posts <- false;
            store.dirty_comments <- false;
            store.last_flush <- Time_compat.now ();
            Ok ())

(** {1 Global Store}

    Uses [Eio.Lazy] for fiber-safe initialization.
    [cancel:`Protect] ensures store creation completes even if the
    forcing fiber is cancelled. *)

let global_lazy : store Eio.Lazy.t ref =
  ref (Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
    let store = create_store () in
    load_persisted_posts store;
    load_persisted_comments store;
    recalculate_reply_counts store;
    load_persisted_votes store;
    store))

let global () = Eio.Lazy.force !global_lazy

(** Reset global store for test isolation. Next [global ()] call creates fresh store.
    Safe: only called from test setup before concurrent fibers exist. *)
let reset_global_for_test () =
  global_lazy := Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
    let store = create_store () in
    load_persisted_posts store;
    load_persisted_comments store;
    recalculate_reply_counts store;
    load_persisted_votes store;
    store)

(** Flush any dirty state to disk. Call on shutdown to prevent data loss. *)
let flush_dirty store =
  with_lock store (fun () ->
    if store.dirty_posts then begin
      rewrite_posts store;
      store.dirty_posts <- false
    end;
    if store.dirty_comments then begin
      rewrite_comments store;
      store.dirty_comments <- false
    end;
    rewrite_vote_log store;
    store.last_flush <- Time_compat.now ()
  )


(** {1 Karma & Flair - Reddit-style} *)

(** Calculate karma (total upvotes) for an agent *)
let get_agent_karma store ~agent_name =
  let all_posts = list_posts store () in
  let post_karma =
    List.fold_left (fun acc (p : post) ->
      if Agent_id.to_string p.author = agent_name then acc + p.votes_up
      else acc
    ) 0 all_posts
  in
  let comment_karma =
    Hashtbl.fold (fun _ (c : comment) acc ->
      if Agent_id.to_string c.author = agent_name then acc + c.votes_up
      else acc
    ) store.comments 0
  in
  post_karma + comment_karma

(** Get karma for all agents (cached) *)
let get_all_karma store =
  match store.karma_cache with
  | Some cached -> cached
  | None ->
      let karma_map = Hashtbl.create 64 in
      Hashtbl.iter (fun _ (p : post) ->
        let author = Agent_id.to_string p.author in
        let current = Hashtbl.find_opt karma_map author |> Option.value ~default:0 in
        Hashtbl.replace karma_map author (current + p.votes_up)
      ) store.posts;
      Hashtbl.iter (fun _ (c : comment) ->
        let author = Agent_id.to_string c.author in
        let current = Hashtbl.find_opt karma_map author |> Option.value ~default:0 in
        Hashtbl.replace karma_map author (current + c.votes_up)
      ) store.comments;
      let result = Hashtbl.fold (fun k v acc -> (k, v) :: acc) karma_map [] in
      store.karma_cache <- Some result;
      result

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

(** Extract flair from content (format: [flair:name] at start) *)
let extract_flair content =
  let re = Re.Pcre.re {|\[flair:([a-z]+)\]|} |> Re.compile in
  match Re.exec_opt re content with
  | Some g ->
    let flair_name = Re.Group.get g 1 in
    (match List.find_opt (fun (name, _, _) -> name = flair_name) available_flairs with
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
    ("classification_reason", `String (post_classification_reason p));
    ("content", `String p.body);
    ("flair", flair_json);
    ("visibility", `String (visibility_to_string p.visibility));
    ("created_at", `Float p.created_at);
    ("updated_at", `Float p.updated_at);
    ("expires_at", `Float p.expires_at);
    ("votes_up", `Int p.votes_up);
    ("votes_down", `Int p.votes_down);
    ("score", `Int (p.votes_up - p.votes_down));
    ("reply_count", `Int p.reply_count);
  ] @ (match p.hearth with Some h -> [("hearth", `String h)] | None -> [])
    @ (match p.thread_id with Some t -> [("thread_id", `String t)] | None -> [])
    @ (match p.meta_json with Some meta -> [("meta", meta)] | None -> []))
