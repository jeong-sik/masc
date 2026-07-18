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
    (match
       Fs_compat.append_private_jsonl_durable_stable_locked_result
         path
         (Yojson.Safe.to_string json ^ "\n")
     with
     | Ok () -> Ok ()
     | Error error -> persist_transaction_error ~where:"append_vote_log" error)
  with Sys_error msg -> persist_io_error ~where:"append_vote_log" msg

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
    rewrite_jsonl_durable_result ~where:"rewrite_vote_log" path content
  with Sys_error msg -> persist_io_error ~where:"rewrite_vote_log" msg

(* [vote_outcome] carries the information needed to run post-lock vote hooks.
   [earn_upvote_for] is [Some author] only on the fresh peer-upvote path — a
   self-upvote is not reputation, a vote flip does not earn credits (prevents
   down/up alternation abuse), and a downvote does not earn at all. *)
type vote_rollback =
  | Post_vote_rollback of {
      key : string;
      previous_target : post;
      applied_target : post;
      previous_vote : (vote_direction * float) option;
      dirty_was_set : bool;
      dirty_id_was_present : bool;
    }
  | Comment_vote_rollback of {
      key : string;
      previous_target : comment;
      applied_target : comment;
      previous_vote : (vote_direction * float) option;
      dirty_was_set : bool;
      dirty_id_was_present : bool;
    }

type vote_outcome = {
  delta : int;
  earn_upvote_for : string option;
  vote_target : string;
  vote_voter : string;
  vote_direction : vote_direction;
  vote_ts : float;
  vote_author_name : string;
  rollback : vote_rollback;
}

type vote_commit =
  | Vote_committed of vote_outcome
  | Vote_commit_unknown of vote_outcome * board_error

let persist_vote_outcome outcome =
  append_vote_log
    ~target:outcome.vote_target
    ~voter:outcome.vote_voter
    ~direction:outcome.vote_direction
    ~ts:outcome.vote_ts

let record_vote_effect outcome =
  let vote_dir =
    match outcome.vote_direction with
    | Up -> Board_effect_hooks.Up
    | Down -> Board_effect_hooks.Down
  in
  Board_effect_hooks.record_vote
    ~agent_name:outcome.vote_author_name
    ~direction:vote_dir

let rollback_vote_outcome store outcome =
  let restore_vote key previous_vote =
    match previous_vote with
    | None -> Hashtbl.remove store.vote_log key
    | Some vote -> Hashtbl.replace store.vote_log key vote
  in
  with_lock store (fun () ->
    match outcome.rollback with
    | Post_vote_rollback
        { key
        ; previous_target
        ; applied_target
        ; previous_vote
        ; dirty_was_set
        ; dirty_id_was_present
        } ->
      let post_id = Post_id.to_string previous_target.id in
      if
        Option.equal ( = ) (Hashtbl.find_opt store.posts post_id) (Some applied_target)
        && Option.equal
             ( = )
             (Hashtbl.find_opt store.vote_log key)
             (Some (outcome.vote_direction, outcome.vote_ts))
      then (
        Hashtbl.replace store.posts post_id previous_target;
        restore_vote key previous_vote;
        if not dirty_id_was_present then Hashtbl.remove store.dirty_post_ids post_id;
        store.dirty_posts <- dirty_was_set || Hashtbl.length store.dirty_post_ids > 0;
        invalidate_post_caches store;
        Ok ())
      else Error "post vote state changed before persistence rollback"
    | Comment_vote_rollback
        { key
        ; previous_target
        ; applied_target
        ; previous_vote
        ; dirty_was_set
        ; dirty_id_was_present
        } ->
      let comment_id = Comment_id.to_string previous_target.id in
      if
        Option.equal
          ( = )
          (Hashtbl.find_opt store.comments comment_id)
          (Some applied_target)
        && Option.equal
             ( = )
             (Hashtbl.find_opt store.vote_log key)
             (Some (outcome.vote_direction, outcome.vote_ts))
      then (
        Hashtbl.replace store.comments comment_id previous_target;
        restore_vote key previous_vote;
        if not dirty_id_was_present
        then Hashtbl.remove store.dirty_comment_ids comment_id;
        store.dirty_comments <- dirty_was_set || Hashtbl.length store.dirty_comment_ids > 0;
        invalidate_comment_caches store;
        Ok ())
      else Error "comment vote state changed before persistence rollback")

let persist_or_rollback_vote store outcome =
  match persist_vote_outcome outcome with
  | Ok () -> Ok (Vote_committed outcome)
  | Error (Persistence_commit_unknown _ as error) ->
    Ok (Vote_commit_unknown (outcome, error))
  | Error persistence_error ->
    (match rollback_vote_outcome store outcome with
     | Ok () -> Error persistence_error
     | Error rollback_error ->
       Error
         (Io_error
            (Printf.sprintf
               "vote persistence failed (%s) and rollback failed (%s)"
               (show_board_error persistence_error)
               rollback_error)))

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
      let board_result : (vote_commit, board_error) Result.t =
        with_persist_lock store (fun () ->
          let mutation =
            with_lock store (fun () ->
              match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
          | None -> Error (Post_not_found post_id)
          | Some post ->
              let vote_key = "post:" ^ Post_id.to_string pid ^ ":" ^ voter in
              let now = Time_compat.now () in
              let previous_vote = Hashtbl.find_opt store.vote_log vote_key in
              let post_key = Post_id.to_string pid in
              let dirty_was_set = store.dirty_posts in
              let dirty_id_was_present = Hashtbl.mem store.dirty_post_ids post_key in
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
                  Hashtbl.replace store.posts (Post_id.to_string pid) flipped;
                  Hashtbl.replace store.vote_log vote_key (direction, now);
                  mark_dirty_post store (Post_id.to_string pid);
                  invalidate_post_caches store;
                  let author_name = Agent_id.to_string post.author in
                  (* No economy earn on flip: prevents down/up alternation abuse *)
                  Ok { delta = flipped.votes_up - flipped.votes_down;
                       earn_upvote_for = None;
                       vote_target = vote_key;
                       vote_voter = voter;
                       vote_direction = direction;
                       vote_ts = now;
                       vote_author_name = author_name;
                       rollback =
                         Post_vote_rollback
                           { key = vote_key
                           ; previous_target = post
                           ; applied_target = flipped
                           ; previous_vote
                           ; dirty_was_set
                           ; dirty_id_was_present
                           } }
              | None ->
                  let updated = match direction with
                    | Up -> { post with votes_up = post.votes_up + 1; updated_at = now }
                    | Down -> { post with votes_down = post.votes_down + 1; updated_at = now }
                  in
                  Hashtbl.replace store.posts (Post_id.to_string pid) updated;
                  Hashtbl.replace store.vote_log vote_key (direction, now);
                  mark_dirty_post store (Post_id.to_string pid);
                  invalidate_post_caches store;
                  let author_name = Agent_id.to_string post.author in
                  let earn =
                    if (=) direction Up && not (String.equal voter author_name)
                    then Some author_name
                    else None
                  in
                  Ok { delta = updated.votes_up - updated.votes_down;
                       earn_upvote_for = earn;
                       vote_target = vote_key;
                       vote_voter = voter;
                       vote_direction = direction;
                       vote_ts = now;
                       vote_author_name = author_name;
                       rollback =
                         Post_vote_rollback
                           { key = vote_key
                           ; previous_target = post
                           ; applied_target = updated
                           ; previous_vote
                           ; dirty_was_set
                           ; dirty_id_was_present
                           } })
          in
          Result.bind mutation (persist_or_rollback_vote store))
      in
      (* Side-effect hooks run outside the store lock. Credit and selection
         observers write their own state on unrelated paths and modify no board
         state, so holding [store.mutex] across their I/O would be gratuitous
         contention with every other reader/writer. *)
      let finish outcome =
        match outcome with
        | { delta; earn_upvote_for = Some author_name; _ } ->
           record_vote_effect outcome;
           (match Board_effect_hooks.earn
              ~base_path:(board_base_path ()) ~agent_name:author_name
              ~kind:Upvote ~reason:"upvote on post" () with
            | Ok () -> ()
            | Error e ->
                Log.BoardLog.warn "board_votes: economy earn failed for %s: %s" author_name e);
           delta
        | { delta; earn_upvote_for = None; _ } ->
           record_vote_effect outcome;
           delta
      in
      (match board_result with
       | Ok (Vote_committed outcome) -> Ok (finish outcome)
       | Ok (Vote_commit_unknown (outcome, error)) ->
         ignore (finish outcome : int);
         Error error
       | Error _ as error -> error)

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
        with_persist_lock store (fun () ->
          let mutation =
            with_lock store (fun () ->
              match Hashtbl.find_opt store.comments (Comment_id.to_string cid) with
        | None -> Error (Comment_not_found comment_id)
        | Some cmt ->
            let vote_key = "comment:" ^ Comment_id.to_string cid ^ ":" ^ voter in
            let now = Time_compat.now () in
            let previous_vote = Hashtbl.find_opt store.vote_log vote_key in
            let comment_key = Comment_id.to_string cid in
            let dirty_was_set = store.dirty_comments in
            let dirty_id_was_present = Hashtbl.mem store.dirty_comment_ids comment_key in
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
                Hashtbl.replace store.comments (Comment_id.to_string cid) flipped;
                Hashtbl.replace store.vote_log vote_key (direction, now);
                mark_dirty_comment store (Comment_id.to_string cid);
                invalidate_comment_caches store;
                let author_name = Agent_id.to_string cmt.author in
                Ok {
                  delta = flipped.votes_up - flipped.votes_down;
                  earn_upvote_for = None;
                  vote_target = vote_key;
                  vote_voter = voter;
                  vote_direction = direction;
                  vote_ts = now;
                  vote_author_name = author_name;
                  rollback =
                    Comment_vote_rollback
                      { key = vote_key
                      ; previous_target = cmt
                      ; applied_target = flipped
                      ; previous_vote
                      ; dirty_was_set
                      ; dirty_id_was_present
                      };
                }
            | None ->
                let updated = match direction with
                  | Up -> { cmt with votes_up = cmt.votes_up + 1 }
                  | Down -> { cmt with votes_down = cmt.votes_down + 1 }
                in
                Hashtbl.replace store.comments (Comment_id.to_string cid) updated;
                Hashtbl.replace store.vote_log vote_key (direction, now);
                mark_dirty_comment store (Comment_id.to_string cid);
                invalidate_comment_caches store;
                let author_name = Agent_id.to_string cmt.author in
                Ok {
                  delta = updated.votes_up - updated.votes_down;
                  earn_upvote_for = None;
                  vote_target = vote_key;
                  vote_voter = voter;
                  vote_direction = direction;
                  vote_ts = now;
                  vote_author_name = author_name;
                  rollback =
                    Comment_vote_rollback
                      { key = vote_key
                      ; previous_target = cmt
                      ; applied_target = updated
                      ; previous_vote
                      ; dirty_was_set
                      ; dirty_id_was_present
                      };
                })
          in
          Result.bind mutation (persist_or_rollback_vote store))
      in
      (match board_result with
       | Ok (Vote_committed outcome) ->
         record_vote_effect outcome;
         Ok outcome.delta
       | Ok (Vote_commit_unknown (outcome, error)) ->
         record_vote_effect outcome;
         Error error
       | Error _ as error -> error)

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

type vote_target =
  | Vote_post of string
  | Vote_comment of string

let vote_target_kind = function
  | Vote_post _ -> "post"
  | Vote_comment _ -> "comment"

(** Parse the legacy vote-row key into [(target, voter)]. The
    loader uses this only at the persistence boundary; runtime decisions remain
    typed. *)
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
       if target_id = "" || voter = ""
       then None
       else
         match kind with
         | "post" -> Some (Vote_post target_id, voter)
         | "comment" -> Some (Vote_comment target_id, voter)
         | _ -> None)
;;

(** Recalculate reply_count for all posts based on actual comments.
    This ensures data consistency after loading from disk. *)
let recalculate_reply_counts store =
  let counts = Hashtbl.create (Hashtbl.length store.posts) in
  Hashtbl.iter
    (fun _ (comment : comment) ->
       let post_key = Post_id.to_string comment.post_id in
       let count = Hashtbl.find_opt counts post_key |> Option.value ~default:0 in
       Hashtbl.replace counts post_key (count + 1))
    store.comments;
  let changed = ref false in
  store.posts
  |> Hashtbl.to_seq
  |> List.of_seq
  |> List.iter (fun (key, (post : post)) ->
       let reply_count = Hashtbl.find_opt counts key |> Option.value ~default:0 in
       if not (Int.equal post.reply_count reply_count)
       then (
         changed := true;
         Hashtbl.replace store.posts key { post with reply_count }));
  if !changed then store.dirty_posts <- true;
  let total = Hashtbl.fold (fun _ count acc -> acc + count) counts 0 in
  Log.BoardLog.debug "recalculated reply_counts: %d total comments across posts" total

let recalculate_vote_counts store =
  let post_counts = Hashtbl.create (Hashtbl.length store.posts) in
  let comment_counts = Hashtbl.create (Hashtbl.length store.comments) in
  let increment counts target direction =
    let votes_up, votes_down =
      Hashtbl.find_opt counts target |> Option.value ~default:(0, 0)
    in
    match direction with
    | Up -> Hashtbl.replace counts target (votes_up + 1, votes_down)
    | Down -> Hashtbl.replace counts target (votes_up, votes_down + 1)
  in
  Hashtbl.iter
    (fun key (direction, _ts) ->
       match parse_vote_key key with
       | Some (Vote_post target_id, _) -> increment post_counts target_id direction
       | Some (Vote_comment target_id, _) ->
         increment comment_counts target_id direction
       | None -> ())
    store.vote_log;
  let posts_changed = ref false in
  store.posts
  |> Hashtbl.to_seq
  |> List.of_seq
  |> List.iter (fun (key, (post : post)) ->
       let votes_up, votes_down =
         Hashtbl.find_opt post_counts key |> Option.value ~default:(0, 0)
       in
       if not (Int.equal post.votes_up votes_up && Int.equal post.votes_down votes_down)
       then (
         posts_changed := true;
         Hashtbl.replace store.posts key { post with votes_up; votes_down }));
  let comments_changed = ref false in
  store.comments
  |> Hashtbl.to_seq
  |> List.of_seq
  |> List.iter (fun (key, (comment : comment)) ->
       let votes_up, votes_down =
         Hashtbl.find_opt comment_counts key |> Option.value ~default:(0, 0)
       in
       if
         not
           (Int.equal comment.votes_up votes_up
            && Int.equal comment.votes_down votes_down)
       then (
         comments_changed := true;
         Hashtbl.replace store.comments key { comment with votes_up; votes_down }));
  if !posts_changed then store.dirty_posts <- true;
  if !comments_changed then store.dirty_comments <- true

let load_persisted_votes store =
  let path = vote_log_path () in
  let decode json =
    match
      ( Safe_ops.json_string_opt "target" json
      , Safe_ops.json_string_opt "direction" json )
    with
    | Some target, Some direction_text ->
      (match vote_direction_of_string_opt direction_text, parse_vote_key target with
       | Some direction, Some (target_kind, _voter) ->
         let ts = Safe_ops.json_float_opt "ts" json |> Option.value ~default:0.0 in
         Some (target, target_kind, direction, ts)
       | None, _ | _, None -> None)
    | _ -> None
  in
  match Board_votes_json.strict_jsonl_rows ~path ~decode with
  | Error _ as error -> error
  | Ok rows ->
    let loaded = ref 0 in
    let discarded = ref false in
    List.iter
      (fun (key, target, direction, ts) ->
         let target_present =
           match target with
           | Vote_post target_id -> Hashtbl.mem store.posts target_id
           | Vote_comment target_id -> Hashtbl.mem store.comments target_id
         in
         if target_present
         then (
           if Hashtbl.mem store.vote_log key then discarded := true;
           Hashtbl.replace store.vote_log key (direction, ts);
           Stdlib.incr loaded)
         else discarded := true)
      rows;
    if !discarded then store.dirty_posts <- true;
    if !loaded > 0
    then Log.BoardLog.info "loaded %d vote entries from %s" !loaded path
    else Log.BoardLog.debug "loaded 0 vote entries from %s" path;
    Ok !loaded

let load_persisted_reactions store =
  let path = reactions_path () in
  match Board_votes_json.strict_jsonl_rows ~path ~decode:reaction_of_yojson with
  | Error _ as error -> error
  | Ok rows ->
    let loaded = ref 0 in
    let discarded = ref false in
    List.iter
      (fun (reaction : reaction) ->
         let target_present =
           match reaction.target_type with
           | Reaction_post -> Hashtbl.mem store.posts reaction.target_id
           | Reaction_comment -> Hashtbl.mem store.comments reaction.target_id
         in
         if target_present
         then (
           let user_id = Agent_id.to_string reaction.user_id in
           let key =
             reaction_key
               ~target_type:reaction.target_type
               ~target_id:reaction.target_id
               ~user_id
               ~emoji:reaction.emoji
           in
           if Hashtbl.mem store.reactions key then discarded := true;
           Hashtbl.replace store.reactions key reaction;
           Stdlib.incr loaded)
         else discarded := true)
      rows;
    if !discarded then store.dirty_posts <- true;
    if !loaded > 0
    then Log.BoardLog.info "loaded %d reactions from %s" !loaded path
    else Log.BoardLog.debug "loaded 0 reactions from %s" path;
    Ok !loaded

exception Invalid_sub_board_projection of string

let load_persisted_sub_boards store =
  let path = sub_boards_path () in
  match Board_votes_json.strict_jsonl_rows ~path ~decode:sub_board_of_yojson with
  | Error _ as error -> error
  | Ok rows ->
    let ids = Hashtbl.create (List.length rows) in
    let slugs = Hashtbl.create (List.length rows) in
    let rec validate = function
      | [] -> Ok ()
      | (sb : sub_board) :: rest ->
        let id = Sub_board_id.to_string sb.id in
        if Hashtbl.mem ids id
        then
          Error
            (path, Invalid_sub_board_projection ("duplicate sub-board id: " ^ id))
        else if Hashtbl.mem slugs sb.slug
        then
          Error
            ( path
            , Invalid_sub_board_projection
                ("duplicate sub-board slug: " ^ sb.slug) )
        else (
          Hashtbl.add ids id ();
          Hashtbl.add slugs sb.slug ();
          validate rest)
    in
    (match validate rows with
     | Error _ as error -> error
     | Ok () ->
       List.iter
         (fun (sb : sub_board) ->
            let id = Sub_board_id.to_string sb.id in
            Hashtbl.replace store.sub_boards id sb;
            Hashtbl.replace store.sub_boards_by_slug sb.slug id)
         rows;
       let loaded = List.length rows in
       if loaded > 0
       then Log.BoardLog.info "loaded %d sub-boards from %s" loaded path
       else Log.BoardLog.debug "loaded 0 sub-boards from %s" path;
       Ok loaded)

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
      with_persist_lock store (fun () ->
        let mutation =
          with_lock store (fun () ->
            let key = Post_id.to_string pid in
            match Hashtbl.find_opt store.posts key with
            | None -> Error (Post_not_found post_id)
            | Some previous ->
              let updated = { previous with thread_id = Some thread_id } in
              Hashtbl.replace store.posts key updated;
              invalidate_post_caches store;
              Ok (key, previous, updated, posts_jsonl_unlocked store))
        in
        match mutation with
        | Error _ as error -> error
        | Ok (key, previous, updated, content) ->
          (match save_posts_jsonl_result content with
           | Ok () -> Ok ()
           | Error (Persistence_commit_unknown _ as error) ->
             with_lock store (fun () -> mark_dirty_post store key);
             Error error
           | Error error ->
             with_lock store (fun () ->
               match Hashtbl.find_opt store.posts key with
               | Some current when current = updated ->
                 Hashtbl.replace store.posts key previous;
                 invalidate_post_caches store
               | Some _ | None -> ());
             Error error))

(** Set a post's [pinned] flag (operator-curated pin, owner-gated at the HTTP
    boundary). Persists immediately via [append_post] (like [create_post]). *)
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
          (match append_post updated with
           | Ok () -> Ok ()
           | Error (Persistence_commit_unknown _ as error) ->
             with_lock store (fun () -> mark_dirty_post store (Post_id.to_string updated.id));
             Error error
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
               Error e))

let posts_jsonl_snapshot store =
  let buf = Buffer.create 4096 in
  Hashtbl.iter (fun _ (pst : post) ->
    Buffer.add_string buf (Yojson.Safe.to_string (post_to_yojson pst));
    Buffer.add_char buf '\n'
  ) store.posts;
  Buffer.contents buf

let comments_jsonl_snapshot = comments_jsonl_unlocked

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
    rewrite_jsonl_durable_result ~where path content
  with Sys_error msg -> persist_io_error ~where msg

(** Persist the projection set in recovery order. [posts] is the root existence
    projection and is committed first. Every normal comment/vote/reaction is
    already synchronously durable before this compaction path runs; boot loading
    rejects rows whose root target is absent and re-derives reply/vote counters.
    This is deliberately not described as a multi-file atomic transaction. *)
let persist_projection_set
      ~posts_where
      ~comments_where
      ~reactions_where
      ~sub_boards_where
      (posts_jsonl, comments_jsonl, votes_jsonl, reactions_jsonl, sub_boards_jsonl)
  =
  let ( let* ) = Result.bind in
  let* () = save_jsonl_snapshot ~where:posts_where ~path:(persist_path ()) posts_jsonl in
  let* () =
    save_jsonl_snapshot ~where:comments_where ~path:(comments_path ()) comments_jsonl
  in
  let* () = save_vote_log_jsonl votes_jsonl in
  let* () =
    save_jsonl_snapshot
      ~where:reactions_where
      ~path:(reactions_path ())
      reactions_jsonl
  in
  save_jsonl_snapshot
    ~where:sub_boards_where
    ~path:(sub_boards_path ())
    sub_boards_jsonl

let full_snapshot_unlocked store =
  ( posts_jsonl_snapshot store
  , comments_jsonl_snapshot store
  , vote_log_jsonl store
  , reactions_jsonl_snapshot store
  , sub_boards_jsonl_unlocked store )

let clear_dirty_if_snapshot_current store snapshot =
  with_lock store (fun () ->
    if full_snapshot_unlocked store = snapshot
    then (
      Hashtbl.clear store.dirty_post_ids;
      Hashtbl.clear store.dirty_comment_ids;
      Hashtbl.clear store.pending_post_durability;
      Hashtbl.clear store.pending_comment_durability;
      Hashtbl.clear store.pending_reaction_durability;
      Hashtbl.clear store.pending_parent_projection_repairs;
      store.dirty_posts <- false;
      store.dirty_comments <- false;
      store.dirty_sub_boards <- false;
      store.last_flush <- Time_compat.now ()))

let delete_post store ~post_id : (unit, board_error) Result.t =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
    with_persist_lock store (fun () ->
      let snapshot =
        with_lock store (fun () ->
      let post_key = Post_id.to_string pid in
      match Hashtbl.find_opt store.posts post_key with
      | None -> Error (Post_not_found post_id)
      | Some _ ->
        let comment_ids =
          Hashtbl.fold
            (fun key (c : comment) acc ->
               if String.equal (Post_id.to_string c.post_id) post_key then key :: acc else acc)
            store.comments
            []
        in
        Hashtbl.remove store.posts post_key;
        Hashtbl.remove store.comments_by_post post_key;
        List.iter
          (fun comment_key ->
             Hashtbl.remove store.comments comment_key)
          comment_ids;
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
        store.dirty_posts <- true;
        store.dirty_comments <- true;
        Ok (full_snapshot_unlocked store))
      in
      match snapshot with
      | Error _ as e -> e
      | Ok snapshot ->
        (match
           persist_projection_set
             ~posts_where:"rewrite_posts"
             ~comments_where:"rewrite_comments"
             ~reactions_where:"rewrite_reactions"
             ~sub_boards_where:"rewrite_sub_boards"
             snapshot
         with
         | Error _ as error -> error
         | Ok () ->
           clear_dirty_if_snapshot_current store snapshot;
           Ok ()))

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
let flush_dirty_locked store =
  let snapshot =
    with_lock store (fun () ->
      if store.dirty_posts || store.dirty_comments || store.dirty_sub_boards
      then Some (full_snapshot_unlocked store)
      else None)
  in
  match snapshot with
  | None -> Ok ()
  | Some snapshot ->
    (match
       persist_projection_set
         ~posts_where:"flush_posts"
         ~comments_where:"flush_comments"
         ~reactions_where:"flush_reactions"
         ~sub_boards_where:"flush_sub_boards"
         snapshot
     with
     | Error _ as error -> error
     | Ok () ->
       clear_dirty_if_snapshot_current store snapshot;
       Ok ())

(** {1 Global Store}

    Uses [Eio.Lazy] for fiber-safe initialization.
    [cancel:`Protect] ensures store creation completes even if the
    forcing fiber is cancelled. *)

exception Board_persistence_unavailable of string

let load_projection ~kind = function
  | Ok count -> Ok count
  | Error (path, cause) ->
    Error
      (Printf.sprintf
         "Board %s projection load failed: path=%s reason=%s"
         kind
         path
         (Printexc.to_string cause))

let load_all_persisted store =
  let ( let* ) = Result.bind in
  let* (_ : int) = load_projection ~kind:"posts" (load_persisted_posts store) in
  let* (_ : int) =
    load_projection ~kind:"comments" (load_persisted_comments store)
  in
  recalculate_reply_counts store;
  let* (_ : int) = load_projection ~kind:"votes" (load_persisted_votes store) in
  recalculate_vote_counts store;
  let* (_ : int) =
    load_projection ~kind:"reactions" (load_persisted_reactions store)
  in
  let* (_ : int) =
    load_projection ~kind:"sub-boards" (load_persisted_sub_boards store)
  in
  match with_persist_lock store (fun () -> flush_dirty_locked store) with
  | Ok () -> Ok ()
  | Error error ->
    Error
      (Printf.sprintf
         "Board projection repair failed: %s"
         (show_board_error error))

let initialize_store () =
  let store = create_store () in
  match load_all_persisted store with
  | Ok () -> store
  | Error detail ->
    Log.BoardLog.error "%s" detail;
    raise (Board_persistence_unavailable detail)

let global_lazy : store Eio.Lazy.t ref =
  ref (Eio.Lazy.from_fun ~cancel:`Protect initialize_store)

let global () = Eio.Lazy.force !global_lazy

(** Reset global store for test isolation. Next [global ()] call creates fresh store.
    Safe: only called from test setup before concurrent fibers exist. *)
let reset_global_for_test () =
  global_lazy := Eio.Lazy.from_fun ~cancel:`Protect initialize_store

let flush_dirty store = with_persist_lock store (fun () -> flush_dirty_locked store)

let sweep_and_flush ?protected_post_ids ?protected_comment_ids store =
  with_persist_lock store (fun () ->
    let removed =
      Board_core.sweep ?protected_post_ids ?protected_comment_ids store
    in
    Result.map (fun () -> removed) (flush_dirty_locked store))


(** {1 Karma & Flair - Reddit-style} *)

(** Scoring contract: returns the karma delta for a vote direction.
    Upvotes earn +1 karma; downvotes do not deduct karma (delta = 0).
    Callers that want to replay or rebuild the ledger must use this
    function as the single source of truth for karma scoring. *)
let karma_score_for_direction = function
  | Up -> 1
  | Down -> 0

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
    | Some (target, voter_raw) ->
        let target_id, recipient_opt =
          match target with
          | Vote_post target_id ->
              (match Hashtbl.find_opt store.posts target_id with
               | Some (p : post) -> target_id, Some (Agent_id.to_string p.author)
               | None -> target_id, None)
          | Vote_comment target_id ->
              (match Hashtbl.find_opt store.comments target_id with
               | Some (c : comment) -> target_id, Some (Agent_id.to_string c.author)
               | None -> target_id, None)
        in
        let voter = canonical_vote_voter voter_raw in
        match recipient_opt with
        | None -> None
        | Some recipient when String.equal recipient voter ->
            (* Content score still records the vote, but karma is
               peer recognition; self-upvotes do not mint reputation. *)
            None
        | Some recipient ->
            Some
              { recipient
              ; voter
              ; target_kind = vote_target_kind target
              ; target_id
              ; delta
              ; ts
              }

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
    ("pinned", `Bool p.pinned);
  ] @ (match p.hearth with Some h -> [("hearth", `String h)] | None -> [])
    @ (match p.thread_id with Some t -> [("thread_id", `String t)] | None -> [])
    (* RFC-0233 §7: the dashboard board serializer ([board_post_dashboard_json])
       funnels every board list/detail route through this function, so emitting
       [origin] here exposes the originating-turn provenance on every
       dashboard-facing post in one place (no per-route N-of-M). Same encoder as
       [post_to_yojson] so the wire shape is identical. *)
    @ (match p.origin with Some o -> [("origin", post_origin_to_yojson o)] | None -> [])
    @ (match post_classification_reason p with
       | Some reason -> [("classification_reason", `String reason)]
       | None -> [])
    @ (match p.meta_json with Some meta -> [("meta", meta)] | None -> []))
