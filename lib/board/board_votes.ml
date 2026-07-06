module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

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

(* Sound partial parser — case-insensitive, trims whitespace, and
   rejects empty input. Missing direction defaults belong at the tool
   boundary, not in the wire-value parser. *)
let vote_direction_of_string_opt raw =
  match String.trim (String.lowercase_ascii raw) with
  | "up" -> Some Up
  | "down" -> Some Down
  | _ -> None

let vote_log_path () =
  let base = board_base_path () in
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path:base)
    "board_votes.jsonl"

(* #10086: [ts] is the cast timestamp supplied by the caller.  Both
   the append (line-append on cast) and the rewrite (atomic flush
   from the in-memory store) MUST serialize the same [ts] for a
   given (target, voter) pair — otherwise analytics keyed on vote
   recency (hot ranking, vote-velocity windows) see fabricated
   timestamps advancing on every flush cycle. *)
let append_vote_log ~target ~voter ~direction ~ts =
  try
    ensure_masc_dir ();
    let path = vote_log_path () in
    let json = `Assoc [
      ("target", `String target);
      ("voter", `String voter);
      ("direction", `String (vote_direction_to_string direction));
      ("ts", `Float ts);
    ] in
    Fs_compat.append_file path (Yojson.Safe.to_string json ^ "\n");
    rotate_if_needed path;
    Ok ()
  with
  | Sys_error msg ->
    record_persist_error ~where:"append_vote_log" msg;
    Error (Io_error (Printf.sprintf "append_vote_log: %s" msg))

let vote_log_jsonl store =
  let buf = Buffer.create 4096 in
  Hashtbl.iter
    (fun target (direction, ts) ->
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
            (* #10086: persist the cast ts stored alongside the
               direction, NOT [Time_compat.now ()].  The previous
               behaviour rewrote every row's timestamp on each
               flush cycle, destroying audit and feeding wrong
               values to hot-ranking / recency scoring. *)
            ("ts", `Float ts);
          ]
      in
      Buffer.add_string buf (Yojson.Safe.to_string json);
      Buffer.add_char buf '\n')
    store.vote_log;
  Buffer.contents buf

let save_vote_log_jsonl content =
  try
    ensure_masc_dir ();
    let path = vote_log_path () in
    match Fs_compat.save_file_atomic path content with
    | Ok () -> Ok ()
    | Error msg ->
      record_persist_error ~where:"rewrite_vote_log" msg;
      Error (Io_error (Printf.sprintf "rewrite_vote_log: %s" msg))
  with
  | Sys_error msg ->
    record_persist_error ~where:"rewrite_vote_log" msg;
    Error (Io_error (Printf.sprintf "rewrite_vote_log: %s" msg))

let rewrite_vote_log store =
  save_vote_log_jsonl (vote_log_jsonl store)

(* [vote_outcome] carries the information needed to run post-lock vote hooks.
   [earn_upvote_for] is [Some author] only on the fresh peer-upvote path — a
   self-upvote is not reputation, a vote flip does not earn credits (prevents
   down/up alternation abuse), and a downvote does not earn at all. *)
type vote_outcome = {
  delta : int;
  earn_upvote_for : string option;
  vote_target : string;
  vote_voter : string;
  vote_direction : vote_direction;
  vote_ts : float;
  vote_author_name : string;
}

type post_vote_mutation = {
  post_key : string;
  previous_post : post;
  previous_vote : (vote_direction * float) option;
  outcome : vote_outcome;
}

type comment_vote_mutation = {
  comment_key : string;
  previous_comment : comment;
  previous_vote : (vote_direction * float) option;
  outcome : vote_outcome;
}

let record_vote_side_effect store outcome =
  match
    with_persist_lock store (fun () ->
      append_vote_log
        ~target:outcome.vote_target
        ~voter:outcome.vote_voter
        ~direction:outcome.vote_direction
        ~ts:outcome.vote_ts)
  with
  | Error _ as e -> e
  | Ok () ->
    let vote_dir =
      match outcome.vote_direction with
      | Up -> Board_effect_hooks.Up
      | Down -> Board_effect_hooks.Down
    in
    Board_effect_hooks.record_vote
      ~agent_name:outcome.vote_author_name
      ~direction:vote_dir;
    Ok ()
;;

let restore_vote_post_after_persist_failure store ~post_key ~previous_post ~vote_key ~previous_vote =
  with_lock store (fun () ->
    Hashtbl.replace store.posts post_key previous_post;
    (match previous_vote with
     | Some vote -> Hashtbl.replace store.vote_log vote_key vote
     | None -> Hashtbl.remove store.vote_log vote_key);
    invalidate_post_caches store)
;;

let restore_vote_comment_after_persist_failure
      store
      ~comment_key
      ~previous_comment
      ~vote_key
      ~previous_vote
  =
  with_lock store (fun () ->
    Hashtbl.replace store.comments comment_key previous_comment;
    (match previous_vote with
     | Some vote -> Hashtbl.replace store.vote_log vote_key vote
     | None -> Hashtbl.remove store.vote_log vote_key);
    invalidate_comment_caches store)

let current_vote_for_post store ~voter ~post_id
    : (vote_direction option, board_error) Result.t =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok agent ->
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      with_lock store (fun () ->
        let post_key = Post_id.to_string pid in
        if not (Hashtbl.mem store.posts post_key) then Error (Post_not_found post_id)
        else
          let vote_key = "post:" ^ post_key ^ ":" ^ Agent_id.to_string agent in
          Ok (Option.map fst (Hashtbl.find_opt store.vote_log vote_key)))

let vote store ~voter ~post_id ~direction : (int, board_error) Result.t =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok agent ->
  let voter = Agent_id.to_string agent in
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      let board_result : (post_vote_mutation, board_error) Result.t =
        with_lock store (fun () ->
          let post_key = Post_id.to_string pid in
          match Hashtbl.find_opt store.posts post_key with
          | None -> Error (Post_not_found post_id)
          | Some post ->
              let vote_key = "post:" ^ post_key ^ ":" ^ voter in
              let now = Time_compat.now () in
              let previous_vote = Hashtbl.find_opt store.vote_log vote_key in
              match previous_vote with
              | Some (prev, _prev_ts) when (=) prev direction ->
                  Error (Already_voted (Printf.sprintf "%s already voted %s on %s"
                    voter (vote_direction_to_string direction) post_id))
              | Some (_opposite, _prev_ts) ->
                  let flipped = match direction with
                    | Up -> { post with votes_up = post.votes_up + 1;
                                        votes_down = max 0 (post.votes_down - 1);
                                        updated_at = now }
                    | Down -> { post with votes_down = post.votes_down + 1;
                                          votes_up = max 0 (post.votes_up - 1);
                                          updated_at = now }
                  in
                  Hashtbl.replace store.posts post_key flipped;
                  Hashtbl.replace store.vote_log vote_key (direction, now);
                  mark_dirty_post store post_key;
                  invalidate_post_caches store;
                  let author_name = Agent_id.to_string post.author in
                  (* No economy earn on flip: prevents down/up alternation abuse *)
                  Ok
                    { post_key
                    ; previous_post = post
                    ; previous_vote
                    ; outcome =
                        { delta = flipped.votes_up - flipped.votes_down
                        ; earn_upvote_for = None
                        ; vote_target = vote_key
                        ; vote_voter = voter
                        ; vote_direction = direction
                        ; vote_ts = now
                        ; vote_author_name = author_name
                        }
                    }
              | None ->
                  let updated = match direction with
                    | Up -> { post with votes_up = post.votes_up + 1; updated_at = now }
                    | Down -> { post with votes_down = post.votes_down + 1; updated_at = now }
                  in
                  Hashtbl.replace store.posts post_key updated;
                  Hashtbl.replace store.vote_log vote_key (direction, now);
                  mark_dirty_post store post_key;
                  invalidate_post_caches store;
                  let author_name = Agent_id.to_string post.author in
                  let earn =
                    if (=) direction Up && not (String.equal voter author_name)
                    then Some author_name
                    else None
                  in
                  Ok
                    { post_key
                    ; previous_post = post
                    ; previous_vote
                    ; outcome =
                        { delta = updated.votes_up - updated.votes_down
                        ; earn_upvote_for = earn
                        ; vote_target = vote_key
                        ; vote_voter = voter
                        ; vote_direction = direction
                        ; vote_ts = now
                        ; vote_author_name = author_name
                        }
                    })
      in
      (* Side-effect hooks run outside the store lock. Credit and selection
         observers write their own state on unrelated paths and modify no board
         state, so holding [store.mutex] across their I/O would be gratuitous
         contention with every other reader/writer. *)
	      (match board_result with
	       | Ok { post_key; previous_post; previous_vote; outcome = ({ delta; earn_upvote_for = Some author_name } as outcome) } ->
	           (match record_vote_side_effect store outcome with
	            | Error _ as e ->
	                restore_vote_post_after_persist_failure
	                  store
	                  ~post_key
	                  ~previous_post
	                  ~vote_key:outcome.vote_target
	                  ~previous_vote;
	                e
	            | Ok () ->
	           (match Board_effect_hooks.earn
	              ~base_path:(board_base_path ()) ~agent_name:author_name
	              ~kind:Upvote ~reason:"upvote on post" () with
	            | Ok () -> ()
	            | Error e ->
	                Log.BoardLog.warn "board_votes: economy earn failed for %s: %s" author_name e);
	           Ok delta)
	       | Ok { post_key; previous_post; previous_vote; outcome = ({ delta; earn_upvote_for = None } as outcome) } ->
	           (match record_vote_side_effect store outcome with
	            | Error _ as e ->
	                restore_vote_post_after_persist_failure
	                  store
	                  ~post_key
	                  ~previous_post
	                  ~vote_key:outcome.vote_target
	                  ~previous_vote;
	                e
	            | Ok () -> Ok delta)
	       | Error _ as e -> e)

let current_vote_for_comment store ~voter ~comment_id
    : (vote_direction option, board_error) Result.t =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok agent ->
  match Comment_id.of_string comment_id with
  | Error e -> Error e
  | Ok cid ->
      with_lock store (fun () ->
        let comment_key = Comment_id.to_string cid in
        if not (Hashtbl.mem store.comments comment_key) then
          Error (Comment_not_found comment_id)
        else
          let vote_key =
            "comment:" ^ comment_key ^ ":" ^ Agent_id.to_string agent
          in
          Ok (Option.map fst (Hashtbl.find_opt store.vote_log vote_key)))

(** Vote on a comment *)
let vote_comment store ~voter ~comment_id ~direction : (int, board_error) Result.t =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok agent ->
  let voter = Agent_id.to_string agent in
  match Comment_id.of_string comment_id with
  | Error e -> Error e
  | Ok cid ->
	      let board_result =
	      with_lock store (fun () ->
	        let comment_key = Comment_id.to_string cid in
	        match Hashtbl.find_opt store.comments comment_key with
	        | None -> Error (Comment_not_found comment_id)
	        | Some cmt ->
	            let vote_key = "comment:" ^ comment_key ^ ":" ^ voter in
	            let now = Time_compat.now () in
	            let previous_vote = Hashtbl.find_opt store.vote_log vote_key in
	            match previous_vote with
	            | Some (prev, _prev_ts) when (=) prev direction ->
	                Error (Already_voted (Printf.sprintf "%s already voted %s on comment %s"
	                  voter (vote_direction_to_string direction) comment_id))
            | Some (_opposite, _prev_ts) ->
                let flipped = match direction with
                  | Up -> { cmt with votes_up = cmt.votes_up + 1;
                                     votes_down = max 0 (cmt.votes_down - 1) }
                  | Down -> { cmt with votes_down = cmt.votes_down + 1;
                                       votes_up = max 0 (cmt.votes_up - 1) }
                in
	                Hashtbl.replace store.comments comment_key flipped;
	                Hashtbl.replace store.vote_log vote_key (direction, now);
	                mark_dirty_comment store comment_key;
	                invalidate_comment_caches store;
	                let author_name = Agent_id.to_string cmt.author in
	                Ok
	                  { comment_key
	                  ; previous_comment = cmt
	                  ; previous_vote
	                  ; outcome =
	                      { delta = flipped.votes_up - flipped.votes_down
	                      ; earn_upvote_for = None
	                      ; vote_target = vote_key
	                      ; vote_voter = voter
	                      ; vote_direction = direction
	                      ; vote_ts = now
	                      ; vote_author_name = author_name
	                      }
	                  }
	            | None ->
	                let updated = match direction with
	                  | Up -> { cmt with votes_up = cmt.votes_up + 1 }
	                  | Down -> { cmt with votes_down = cmt.votes_down + 1 }
	                in
	                Hashtbl.replace store.comments comment_key updated;
	                Hashtbl.replace store.vote_log vote_key (direction, now);
	                mark_dirty_comment store comment_key;
	                invalidate_comment_caches store;
	                let author_name = Agent_id.to_string cmt.author in
	                Ok
	                  { comment_key
	                  ; previous_comment = cmt
	                  ; previous_vote
	                  ; outcome =
	                      { delta = updated.votes_up - updated.votes_down
	                      ; earn_upvote_for = None
	                      ; vote_target = vote_key
	                      ; vote_voter = voter
	                      ; vote_direction = direction
	                      ; vote_ts = now
	                      ; vote_author_name = author_name
	                      }
	                  })
	      in
	      match board_result with
	      | Error _ as e -> e
	      | Ok { comment_key; previous_comment; previous_vote; outcome } ->
	        (match record_vote_side_effect store outcome with
	         | Error _ as e ->
	           restore_vote_comment_after_persist_failure
	             store
	             ~comment_key
	             ~previous_comment
	             ~vote_key:outcome.vote_target
	             ~previous_vote;
	           e
	         | Ok () -> Ok outcome.delta)

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
let load_persisted_posts = Board_votes_json.load_persisted_posts
let load_persisted_comments = Board_votes_json.load_persisted_comments

let record_sub_board_member_ids_read_drop () =
  Board_metrics_hooks.inc_persistence_read_drop
    ~surface:Board_metrics_hooks.Board_sub_board_member_ids
    ~reason:Read_drop_reason.Invalid_payload
;;

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

(** #9921 / #9903: fixture-pattern detection for persisted votes.

    Rationale: test fixture patterns should never appear in the
    production vote ledger. If they do, the ledger was corrupted at
    some earlier point (e.g. a pre-2026-04-18 test run that
    inherited the operator's MASC_BASE_PATH before the
    [(MASC_BASE_PATH "")] dune env-vars block landed in #8274).
    The detector surfaces the contamination at load time so
    operators see the problem immediately instead of the silent-
    persist failure mode that caused #9903.

    Pattern set is deliberately narrow and is applied only to the
    voter segment of the persisted target. Known production patterns
    are automation-agent IDs — none of
    which collide with the fixture patterns below.

    Env var: [MASC_BOARD_VOTE_QUARANTINE=1] promotes detection from
    warn-and-load to skip-fixture-rows. Defaults to warn-only to
    avoid surprising live operators.

    RFC-0089 §4-3 G2: voter classification is now typed via
    {!voter_kind}.  The boundary parser {!classify_voter_target}
    extracts the voter segment from the persisted target key and
    derives the variant once; downstream call sites pattern-match
    instead of re-running [String.starts_with]. *)

type fixture_voter_kind =
  | Hot_voter           (* "hot-voter-" prefix *)
  | Synthetic_voter     (* "synthetic-voter-" prefix *)
  | Test_voter          (* "test-voter-" prefix *)

type voter_kind =
  | Production_voter
  | Fixture_voter of fixture_voter_kind

let extract_voter_segment target =
  match String.rindex_opt target ':' with
  | Some idx when idx + 1 < String.length target ->
      String.sub target (idx + 1) (String.length target - idx - 1)
  | _ -> target

let classify_voter_target (target : string) : voter_kind =
  let voter = extract_voter_segment target in
  if String.starts_with ~prefix:"hot-voter-" voter then Fixture_voter Hot_voter
  else if String.starts_with ~prefix:"synthetic-voter-" voter then
    Fixture_voter Synthetic_voter
  else if String.starts_with ~prefix:"test-voter-" voter then
    Fixture_voter Test_voter
  else Production_voter

let quarantine_enabled () =
  (* #9886: production ledger observed 112/112 (100%) fixture-pattern
     votes orphaning downstream ranking/scoring. Fixture voters
     ([hot-voter-*], [synthetic-voter-*], [test-voter-*]) never appear
     in legitimate production traffic, so default the quarantine ON.
     Operators who intentionally want fixture votes loaded (e.g. a
     benchmark replay against a live ledger) can set the env to [0],
     [false], or [off].  #9921 still tracks the root-cause write path;
     this change keeps downstream stats honest in the meantime. *)
  match Sys.getenv_opt "MASC_BOARD_VOTE_QUARANTINE" with
  | Some v ->
      let norm = String.lowercase_ascii (String.trim v) in
      not (String.equal norm "0" || String.equal norm "false" || String.equal norm "off" || String.equal norm "")
  | None -> true

let load_persisted_votes store =
  let path = vote_log_path () in
  if not (Fs_compat.file_exists path) then Ok 0
  else begin
    try
      let loaded = ref 0 in
      let quarantined = ref 0 in
      let fixture_detected = ref 0 in
      let quarantine = quarantine_enabled () in
      let lines = Fs_compat.load_jsonl path in
      List.iter (fun json ->
        match Safe_ops.json_string_opt "target" json,
              Safe_ops.json_string_opt "direction" json with
        | Some target, Some dir_str ->
          (match vote_direction_of_string_opt dir_str with
           | None -> ()
           | Some direction ->
             (* #10086: legacy rows persisted before this fix may have
                [ts] overwritten by a prior flush cycle.  Use the
                recorded value when present; fall back to 0.0 rather
                than [Time_compat.now ()] — loading a ledger at server
                start time must NOT advance the ts of every pre-fix
                vote to "now".  Downstream readers treat ts=0.0 as
                "unknown cast time". *)
             let ts =
               match Safe_ops.json_float_opt "ts" json with
               | Some t -> t
               | None -> 0.0
             in
             (match classify_voter_target target with
              | Fixture_voter _ ->
                  Stdlib.incr fixture_detected;
                  if quarantine then Stdlib.incr quarantined
                  else begin
                    Hashtbl.replace store.vote_log target (direction, ts);
                    Stdlib.incr loaded
                  end
              | Production_voter ->
                  Hashtbl.replace store.vote_log target (direction, ts);
                  Stdlib.incr loaded))
        | _ -> ()
      ) lines;
      if !fixture_detected > 0 then begin
        Board_metrics_hooks.inc_vote_fixture_detected
          ~count:!fixture_detected;
        Log.BoardLog.warn
          "#9921 fixture contamination: %d vote rows match fixture patterns \
           (hot-voter-*, synthetic-voter-*, :test-voter-*) in %s. Live \
           ledger was written by a test fixture at some point. Loaded=%d \
           quarantined=%d (MASC_BOARD_VOTE_QUARANTINE=%b). Truncation \
           is an operator decision; see #9921."
          !fixture_detected path !loaded !quarantined quarantine
      end;
      if !loaded > 0 then
        Log.BoardLog.info "loaded %d vote entries from %s" !loaded path
      else
        Log.BoardLog.debug "loaded 0 vote entries from %s" path;
      Ok !loaded
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (path, e)
  end

let load_persisted_reactions store =
  let path = reactions_path () in
  if not (Fs_compat.file_exists path) then Ok 0
  else begin
    try
      let loaded = ref 0 in
      let lines = Fs_compat.load_jsonl path in
      List.iter
        (fun json ->
           match reaction_of_yojson json with
           | Some reaction ->
               let user_id = Agent_id.to_string reaction.user_id in
               let key =
                 reaction_key ~target_type:reaction.target_type
                   ~target_id:reaction.target_id ~user_id
                   ~emoji:reaction.emoji
               in
               Hashtbl.replace store.reactions key reaction;
               Stdlib.incr loaded
           | None -> ())
        lines;
      if !loaded > 0 then
        Log.BoardLog.info "loaded %d reactions from %s" !loaded path
      else
        Log.BoardLog.debug "loaded 0 reactions from %s" path;
      Ok !loaded
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (path, e)
  end

let load_persisted_sub_boards store =
  let path = sub_boards_path () in
  if not (Fs_compat.file_exists path) then Ok 0
  else begin
    try
      let loaded = ref 0 in
      let lines = Fs_compat.load_jsonl path in
      List.iter
        (fun json ->
           let report = sub_board_of_yojson_report json in
           List.iter
             (fun _ -> record_sub_board_member_ids_read_drop ())
             report.member_errors;
           match report.sub_board with
           | Some sb ->
             let id = Sub_board_id.to_string sb.id in
             Hashtbl.replace store.sub_boards id sb;
             Hashtbl.replace store.sub_boards_by_slug sb.slug id;
             Stdlib.incr loaded
           | None -> ())
        lines;
      if !loaded > 0 then
        Log.BoardLog.info "loaded %d sub-boards from %s" !loaded path
      else
        Log.BoardLog.debug "loaded 0 sub-boards from %s" path;
      Ok !loaded
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (path, e)
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
          (match with_persist_lock store (fun () -> append_post updated) with
           | Ok () -> Ok ()
           | Error e ->
               with_lock store (fun () ->
                 let key = Post_id.to_string previous.id in
                 (match Hashtbl.find_opt store.posts key with
                  | Some current
                    when current.pinned = updated.pinned
                         && Stdlib.Float.equal current.updated_at updated.updated_at ->
                    Hashtbl.replace store.posts key previous;
                    invalidate_post_caches store
                  | _ -> ()));
               Error e)

let posts_jsonl_snapshot store =
  let buf = Buffer.create 4096 in
  Hashtbl.iter (fun _ (pst : post) ->
    Buffer.add_string buf (Yojson.Safe.to_string (post_to_yojson pst));
    Buffer.add_char buf '\n'
  ) store.posts;
  Buffer.contents buf

let comments_jsonl_snapshot store =
  let buf = Buffer.create 4096 in
  Hashtbl.iter (fun _ (cmt : comment) ->
    Buffer.add_string buf (Yojson.Safe.to_string (comment_to_yojson cmt));
    Buffer.add_char buf '\n'
  ) store.comments;
  Buffer.contents buf

let reactions_jsonl_snapshot store =
  let buf = Buffer.create 4096 in
  Hashtbl.iter
    (fun _ (reaction : reaction) ->
       Buffer.add_string buf (Yojson.Safe.to_string (reaction_to_yojson reaction));
       Buffer.add_char buf '\n')
    store.reactions;
  Buffer.contents buf

let save_jsonl_snapshot ~where ~path content =
  try
    ensure_masc_dir ();
    match Fs_compat.save_file_atomic path content with
    | Ok () -> Ok ()
    | Error msg ->
      record_persist_error ~where msg;
      Error (Io_error (Printf.sprintf "%s: %s" where msg))
  with
  | Sys_error msg ->
    record_persist_error ~where msg;
    Error (Io_error (Printf.sprintf "%s: %s" where msg))

type delete_post_snapshot =
  { post_key : string
  ; post : post
  ; comments_by_post : string list option
  ; comments : (string * comment) list
  ; votes : (string * (vote_direction * float)) list
  ; reactions : (string * reaction) list
  ; post_count : int
  ; dirty_posts : bool
  ; dirty_comments : bool
  ; dirty_post_ids : string list
  ; dirty_comment_ids : string list
  ; last_flush : float
  ; posts_jsonl : string
  ; comments_jsonl : string
  ; votes_jsonl : string
  ; reactions_jsonl : string
  }

let persist_delete_post_snapshot snapshot =
  let ( let* ) = Result.bind in
  let* () =
    save_jsonl_snapshot
      ~where:"rewrite_posts"
      ~path:(persist_path ())
      snapshot.posts_jsonl
  in
  let* () =
    save_jsonl_snapshot
      ~where:"rewrite_comments"
      ~path:(comments_path ())
      snapshot.comments_jsonl
  in
  let* () = save_vote_log_jsonl snapshot.votes_jsonl in
  save_jsonl_snapshot
    ~where:"rewrite_reactions"
    ~path:(reactions_path ())
    snapshot.reactions_jsonl
;;

let restore_delete_post_snapshot store snapshot =
  with_lock store (fun () ->
    Hashtbl.replace store.posts snapshot.post_key snapshot.post;
    (match snapshot.comments_by_post with
     | Some ids -> Hashtbl.replace store.comments_by_post snapshot.post_key ids
     | None -> Hashtbl.remove store.comments_by_post snapshot.post_key);
    List.iter
      (fun (key, comment) -> Hashtbl.replace store.comments key comment)
      snapshot.comments;
    List.iter
      (fun (key, vote) -> Hashtbl.replace store.vote_log key vote)
      snapshot.votes;
    List.iter
      (fun (key, reaction) -> Hashtbl.replace store.reactions key reaction)
      snapshot.reactions;
    store.post_count := snapshot.post_count;
    store.dirty_posts <- snapshot.dirty_posts;
    store.dirty_comments <- snapshot.dirty_comments;
    Hashtbl.clear store.dirty_post_ids;
    List.iter (fun key -> Hashtbl.replace store.dirty_post_ids key ()) snapshot.dirty_post_ids;
    Hashtbl.clear store.dirty_comment_ids;
    List.iter
      (fun key -> Hashtbl.replace store.dirty_comment_ids key ())
      snapshot.dirty_comment_ids;
    store.last_flush <- snapshot.last_flush;
    invalidate_post_caches store;
    invalidate_comment_caches store)
;;

let delete_post store ~post_id : (unit, board_error) Result.t =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
    let snapshot =
      with_lock store (fun () ->
      let post_key = Post_id.to_string pid in
	      match Hashtbl.find_opt store.posts post_key with
	      | None -> Error (Post_not_found post_id)
	      | Some post ->
	        let previous_comments_by_post = Hashtbl.find_opt store.comments_by_post post_key in
	        let previous_post_count = !(store.post_count) in
	        let previous_dirty_posts = store.dirty_posts in
	        let previous_dirty_comments = store.dirty_comments in
	        let previous_dirty_post_ids =
	          Hashtbl.fold (fun key () acc -> key :: acc) store.dirty_post_ids []
	        in
	        let previous_dirty_comment_ids =
	          Hashtbl.fold (fun key () acc -> key :: acc) store.dirty_comment_ids []
	        in
	        let previous_last_flush = store.last_flush in
	        let comment_ids =
	          Hashtbl.fold
	            (fun key (c : comment) acc ->
	               if String.equal (Post_id.to_string c.post_id) post_key then key :: acc else acc)
	            store.comments
	            []
	        in
	        let comments =
	          List.filter_map
	            (fun key -> Option.map (fun comment -> key, comment) (Hashtbl.find_opt store.comments key))
	            comment_ids
	        in
	        Hashtbl.remove store.posts post_key;
	        Hashtbl.remove store.comments_by_post post_key;
	        List.iter (fun comment_key -> Hashtbl.remove store.comments comment_key) comment_ids;
        let vote_keys =
          Hashtbl.fold
            (fun key _ acc ->
               if
                 String.starts_with ~prefix:("post:" ^ post_key ^ ":") key
                 || List.exists
                      (fun comment_key ->
                         String.starts_with
                           ~prefix:("comment:" ^ comment_key ^ ":")
                           key)
                      comment_ids
               then key :: acc
               else acc)
	            store.vote_log
	            []
	        in
	        let votes =
	          List.filter_map
	            (fun key -> Option.map (fun vote -> key, vote) (Hashtbl.find_opt store.vote_log key))
	            vote_keys
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
	        let reactions =
	          List.filter_map
	            (fun key ->
	               Option.map
	                 (fun reaction -> key, reaction)
	                 (Hashtbl.find_opt store.reactions key))
	            reaction_keys
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
        let posts_jsonl = posts_jsonl_snapshot store in
	        let comments_jsonl = comments_jsonl_snapshot store in
	        let votes_jsonl = vote_log_jsonl store in
	        let reactions_jsonl = reactions_jsonl_snapshot store in
	        Ok
	          { post_key
	          ; post
	          ; comments_by_post = previous_comments_by_post
	          ; comments
	          ; votes
	          ; reactions
	          ; post_count = previous_post_count
	          ; dirty_posts = previous_dirty_posts
	          ; dirty_comments = previous_dirty_comments
	          ; dirty_post_ids = previous_dirty_post_ids
	          ; dirty_comment_ids = previous_dirty_comment_ids
	          ; last_flush = previous_last_flush
	          ; posts_jsonl
	          ; comments_jsonl
	          ; votes_jsonl
	          ; reactions_jsonl
	          })
	    in
	    (match snapshot with
	     | Error _ as e -> e
	     | Ok snapshot ->
	       (match with_persist_lock store (fun () -> persist_delete_post_snapshot snapshot) with
	        | Ok () -> Ok ()
	        | Error _ as e ->
	          restore_delete_post_snapshot store snapshot;
	          e))

(** {1 Global Store}

    Uses [Eio.Lazy] for fiber-safe initialization.
    [cancel:`Protect] ensures store creation completes even if the
    forcing fiber is cancelled. *)

(* Loaders return [(int, string * exn) result] so the caller is forced to
   acknowledge persistence-load failures.  Best-effort semantics live here
   at the call site, not hidden inside the loader bodies. *)
let log_persistence_result ~kind = function
  | Ok _ -> ()
  | Error (path, e) ->
    Log.BoardLog.error
      "load %s failed: path=%s reason=%s (continuing with best-effort partial state)"
      kind path (Printexc.to_string e)

let load_all_persisted store =
  log_persistence_result ~kind:"posts" (load_persisted_posts store);
  log_persistence_result ~kind:"comments" (load_persisted_comments store);
  recalculate_reply_counts store;
  log_persistence_result ~kind:"votes" (load_persisted_votes store);
  log_persistence_result ~kind:"reactions" (load_persisted_reactions store);
  log_persistence_result ~kind:"sub-boards" (load_persisted_sub_boards store)

let global_lazy : store Eio.Lazy.t ref =
  ref (Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
    let store = create_store () in
    load_all_persisted store;
    store))

let global () = Eio.Lazy.force !global_lazy

(** Reset global store for test isolation. Next [global ()] call creates fresh store.
    Safe: only called from test setup before concurrent fibers exist. *)
let reset_global_for_test () =
  reset_comment_rate_tracker ();
  global_lazy := Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
    let store = create_store () in
    load_all_persisted store;
    store)

(** Flush any dirty state to disk. Call on shutdown to prevent data loss.

    RFC-0091 (board persistence path unification): mutation/vote flushes
    write a full snapshot via [save_jsonl_snapshot] instead of replaying
    the dirty list through [append_post]/[append_comment]. The previous
    [List.iter append_post posts] grew [board_posts.jsonl] by one line per
    vote/mutation per post, sharing the same .id, producing the dup vector
    that motivated the RFC. The snapshot path was already canonical for
    restart-load ([load_persisted_posts]), so promoting it to the
    flush-write path makes [board_posts.jsonl] a true snapshot file with
    one line per id and atomic rewrite semantics. *)
let restore_dirty_flush_state
      store
      ~dirty_posts
      ~dirty_comments
      ~dirty_post_ids
      ~dirty_comment_ids
      ~last_flush
  =
  with_lock store (fun () ->
    store.dirty_posts <- dirty_posts;
    store.dirty_comments <- dirty_comments;
    Hashtbl.clear store.dirty_post_ids;
    List.iter (fun key -> Hashtbl.replace store.dirty_post_ids key ()) dirty_post_ids;
    Hashtbl.clear store.dirty_comment_ids;
    List.iter
      (fun key -> Hashtbl.replace store.dirty_comment_ids key ())
      dirty_comment_ids;
    store.last_flush <- last_flush)
;;

let flush_dirty store =
  let snapshot =
    with_lock store (fun () ->
      let had_dirty = store.dirty_posts || store.dirty_comments in
      let posts_jsonl = if had_dirty then Some (posts_jsonl_snapshot store) else None in
      let comments_jsonl =
        if had_dirty then Some (comments_jsonl_snapshot store) else None
      in
      let vote_log = if had_dirty then Some (vote_log_jsonl store) else None in
      let previous_dirty_posts = store.dirty_posts in
      let previous_dirty_comments = store.dirty_comments in
      let previous_dirty_post_ids =
        Hashtbl.fold (fun key () acc -> key :: acc) store.dirty_post_ids []
      in
      let previous_dirty_comment_ids =
        Hashtbl.fold (fun key () acc -> key :: acc) store.dirty_comment_ids []
      in
      let previous_last_flush = store.last_flush in
      Hashtbl.clear store.dirty_post_ids;
      Hashtbl.clear store.dirty_comment_ids;
      store.dirty_posts <- false;
      store.dirty_comments <- false;
      store.last_flush <- Time_compat.now ();
      ( posts_jsonl
      , comments_jsonl
      , vote_log
      , previous_dirty_posts
      , previous_dirty_comments
      , previous_dirty_post_ids
      , previous_dirty_comment_ids
      , previous_last_flush ))
  in
  let
    ( posts_jsonl
    , comments_jsonl
    , vote_log
    , previous_dirty_posts
    , previous_dirty_comments
    , previous_dirty_post_ids
    , previous_dirty_comment_ids
    , previous_last_flush )
    =
    snapshot
  in
  let persist_result =
    with_persist_lock store (fun () ->
      let ( let* ) = Result.bind in
      let* () =
        match posts_jsonl with
        | None -> Ok ()
        | Some content ->
          save_jsonl_snapshot ~where:"flush_posts" ~path:(persist_path ()) content
      in
      let* () =
        match comments_jsonl with
        | None -> Ok ()
        | Some content ->
          save_jsonl_snapshot ~where:"flush_comments" ~path:(comments_path ()) content
      in
      match vote_log with
      | None -> Ok ()
      | Some content -> save_vote_log_jsonl content)
  in
  match persist_result with
  | Ok () -> Ok ()
  | Error _ as e ->
    restore_dirty_flush_state
      store
      ~dirty_posts:previous_dirty_posts
      ~dirty_comments:previous_dirty_comments
      ~dirty_post_ids:previous_dirty_post_ids
      ~dirty_comment_ids:previous_dirty_comment_ids
      ~last_flush:previous_last_flush;
    e


(** {1 Karma & Flair - Reddit-style} *)

(** Scoring contract: returns the karma delta for a vote direction.
    Upvotes earn +1 karma; downvotes do not deduct karma (delta = 0).
    Callers that want to replay or rebuild the ledger must use this
    function as the single source of truth for karma scoring. *)
let karma_score_for_direction = function
  | Up -> 1
  | Down -> 0

(** Parse a vote-log key into [(target_kind, target_id, voter)].

    Key format: ["post:<id>:<voter>"] or ["comment:<id>:<voter>"].
    Both [<id>] and [<voter>] are safe for the ID character set but
    voter may contain a colon in namespace:agent form, so we split
    only on the first two colons and keep the remainder as voter. *)
let parse_vote_key key =
  match String.index_opt key ':' with
  | None -> None
  | Some i1 ->
      let kind = String.sub key 0 i1 in
      let rest1 = String.sub key (i1 + 1) (String.length key - i1 - 1) in
      (match String.index_opt rest1 ':' with
      | None -> None
      | Some i2 ->
          let target_id = String.sub rest1 0 i2 in
          let voter =
            String.sub rest1 (i2 + 1) (String.length rest1 - i2 - 1)
          in
          if kind = "" || target_id = "" || voter = "" then None
          else Some (kind, target_id, voter))

let canonical_vote_voter voter =
  match Agent_id.of_string voter with
  | Ok agent -> Agent_id.to_string agent
  | Error _ -> String.trim voter

let karma_event_of_vote store key (direction, ts) =
  let delta = karma_score_for_direction direction in
  if delta = 0 then None
  else
    match parse_vote_key key with
    | None -> None
    | Some (kind, target_id, voter_raw) ->
        let recipient_opt =
          match kind with
          | "post" ->
              (match Hashtbl.find_opt store.posts target_id with
               | Some (p : post) -> Some (Agent_id.to_string p.author)
               | None -> None)
          | "comment" ->
              (match Hashtbl.find_opt store.comments target_id with
               | Some (c : comment) -> Some (Agent_id.to_string c.author)
               | None -> None)
          | _ -> None
        in
        let voter = canonical_vote_voter voter_raw in
        match recipient_opt with
        | None -> None
        | Some recipient when String.equal recipient voter ->
            (* Content score still records the vote, but karma is
               peer recognition; self-upvotes do not mint reputation. *)
            None
        | Some recipient ->
            Some { recipient; voter; target_kind = kind; target_id; delta; ts }

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
  let tbl = Hashtbl.create 64 in
  List.iter (fun (e : karma_event) ->
    let prev = Hashtbl.find_opt tbl e.recipient |> Option.value ~default:0 in
    Hashtbl.replace tbl e.recipient (prev + e.delta)
  ) events;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []
  |> List.sort (fun (_, a) (_, b) -> Int.compare b a)

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
    ("target_kind", `String e.target_kind);
    ("target_id",   `String e.target_id);
    ("delta",       `Int    e.delta);
    ("ts",          `Float  e.ts);
    ("ts_iso",      `String ts_iso);
  ]

(** Get karma for all agents (cached).

    Cache check / rebuild / write are all performed inside one
    [with_lock] block — same pattern as [Board_core.list_posts] for
    [sorted_posts_cache].  Previously the read at [store.karma_cache]
    and the write to it lived outside [with_lock] while
    [Board_core.invalidate_*_caches] (callers always hold the lock)
    cleared the field under lock — so two fibers could both observe
    [None] and both rebuild, and an invalidation occurring between an
    unlocked read of a stale [Some _] and a downstream consumer was
    silently lost.  Hashtbl iteration / fold / List.sort are pure CPU
    with no fiber yields, so holding the Eio mutex during the rebuild
    is safe. *)
let get_all_karma store =
  with_lock store (fun () ->
    match store.karma_cache with
    | Some cached -> cached
    | None ->
        let tbl = Hashtbl.create 64 in
        Hashtbl.iter
          (fun key vote ->
             match karma_event_of_vote store key vote with
             | None -> ()
             | Some (e : karma_event) ->
                 let prev =
                   Hashtbl.find_opt tbl e.recipient
                   |> Option.value ~default:0
                 in
                 Hashtbl.replace tbl e.recipient (prev + e.delta))
          store.vote_log;
        let result =
          Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []
          |> List.sort (fun (_, a) (_, b) -> Int.compare b a)
        in
        store.karma_cache <- Some result;
        result)

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
    ("classification_reason", `String (post_classification_reason p));
    ("content", `String p.body);
    ( "mention_ids"
    , `List (List.map (fun id -> `String (Mention_id.to_string id)) p.mention_ids)
    );
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
  ] @ (match p.hearth with Some h -> [("hearth", `String h)] | None -> [])
    @ (match p.thread_id with Some t -> [("thread_id", `String t)] | None -> [])
    (* RFC-0233 §7: the dashboard board serializer ([board_post_dashboard_json])
       funnels every board list/detail route through this function, so emitting
       [origin] here exposes the originating-turn provenance on every
       dashboard-facing post in one place (no per-route N-of-M). Same encoder as
       [post_to_yojson] so the wire shape is identical. *)
    @ (match p.origin with Some o -> [("origin", post_origin_to_yojson o)] | None -> [])
    @ (match p.meta_json with Some meta -> [("meta", meta)] | None -> []))
