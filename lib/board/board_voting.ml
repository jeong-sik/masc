open Board_core_persist

open Result.Syntax

let vote_direction_to_string = Board_vote_row.direction_to_string

(* Variant witness used to derive the schema enum from the canonical encoder. *)
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

let vote_log_path store = Board_paths.store_file_path store Board_paths.Votes

(* Finish a known settlement before logging, preserving the shared carrier
   when the logger itself observes a reserved exception. *)
let finish_vote_write outcome result =
  let result = Board_votes_source.finish_write outcome result in
  try
    (match result with
     | Ok _ -> ()
     | Error error -> record_persist_error ~where:"votes source" (show_board_error error));
    result
  with exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Board_posts_source.defer_reserved ~result:(Result.map (fun _ -> ()) result)
      exception_ backtrace;
    Printexc.raise_with_backtrace exception_ backtrace

let publish_vote_write store outcome publish =
  let module Source = Board_votes_source in
  let result = match outcome with
    | Source.Written { publication; _ } ->
      let projected =
        try publish () with exception_ ->
          Source.fail_publication store publication exception_ (Printexc.get_raw_backtrace ()) in
      (match projected with
       | Ok value ->
         let* () = Source.acknowledge_publication store publication in
         Ok value
       | Error error ->
         Source.reject_publication store publication error;
         Error error)
    | Source.Not_written _ | Source.Unknown _ ->
      Error (Io_error "Board data is unavailable.") in
  finish_vote_write outcome result

let vote_log_jsonl store =
  let buf = Buffer.create 4096 in
  Hashtbl.iter
    (fun target (direction, ts) ->
      let vote =
        match Board_vote_key.of_string target with
        | Some vote -> vote
        | None -> invalid_arg (Printf.sprintf "invalid in-memory vote key: %S" target)
      in
      let json = Board_vote_row.to_yojson (vote, direction, ts) in
      Buffer.add_string buf (Yojson.Safe.to_string json);
      Buffer.add_char buf '\n')
    store.vote_log;
  Buffer.contents buf

(* The captured deletion/flush model is already installed under this same
   persistence interval. Acknowledge only the exact successful file receipt. *)
let save_vote_log_jsonl store content : (unit, board_error) Result.t =
  publish_vote_write store (Board_votes_source.rewrite store content) (fun () -> Ok ())

(* The caller retains persistence through its fresh state publication, so a
   snapshot cannot remove this row between append and memory commit. *)
let append_admitted_vote store ~vote ~direction ~ts publish =
  let* () = Board_votes_source.require_readable store in
  let* () = require_posts_source_readable store in
  publish_vote_write store (Board_votes_source.append store (vote, direction, ts)) publish

let current_vote_for_post store ~voter ~post_id
    : (vote_direction option, board_error) Result.t =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok agent ->
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      with_persist_lock store @@ fun () ->
      let* () = Board_votes_source.require_readable store in
      with_lock store (fun () ->
        let post_key = Post_id.to_string pid in
        if not (Hashtbl.mem store.posts post_key) then Error (Post_not_found post_id)
        else
          let vote_key =
            Board_vote_key.post ~post_id:pid ~voter:agent |> Board_vote_key.to_string
          in
          Ok (Option.map fst (Hashtbl.find_opt store.vote_log vote_key)))

(* Write-ahead under one persistence interval: stage under the state lock,
   append outside it, then publish under a fresh state lock. Snapshot writers
   and other casts cannot pass the durable row before its memory publication.
   A fresh read preserves unrelated state-only edits. Rejection or an append
   failure occurs before any vote mutation, so nothing needs rollback. *)
let vote store ~voter ~post_id ~direction : (int, board_error) Result.t =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok agent ->
  let voter = Agent_id.to_string agent in
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      with_persist_lock store @@ fun () ->
      let* () = Board_votes_source.require_readable store in
      let post_key = Post_id.to_string pid in
      let vote_id = Board_vote_key.post ~post_id:pid ~voter:agent in
      let vote_key = Board_vote_key.to_string vote_id in
      let staged : (float, board_error) Result.t =
        with_lock store (fun () ->
          match Hashtbl.find_opt store.posts post_key with
          | None -> Error (Post_not_found post_id)
          | Some _post ->
              let previous = Option.map fst (Hashtbl.find_opt store.vote_log vote_key) in
              match Board_vote_transition.decide ~previous ~direction with
              | Board_vote_transition.Already_cast ->
                  Error (Already_voted (Printf.sprintf "%s already voted %s on %s"
                    voter (vote_direction_to_string direction) post_id))
              | Board_vote_transition.Cast _ -> Ok (Time_compat.now ()))
      in
      (match staged with
       | Error _ as e -> e
       | Ok ts ->
         append_admitted_vote store ~vote:vote_id ~direction ~ts (fun () ->
              with_lock store (fun () ->
                match Hashtbl.find_opt store.posts post_key with
                | None -> Error (Post_not_found post_id)
                | Some post ->
                  let previous = Option.map fst (Hashtbl.find_opt store.vote_log vote_key) in
                  match Board_vote_transition.decide ~previous ~direction with
                  | Board_vote_transition.Already_cast ->
                      Error (Already_voted (Printf.sprintf "%s already voted %s on %s"
                        voter (vote_direction_to_string direction) post_id))
                  | Board_vote_transition.Cast transition ->
                      let votes_up, votes_down =
                        Board_vote_transition.apply_counts transition
                          ~votes_up:post.votes_up ~votes_down:post.votes_down
                      in
                      (* [ts] was taken before the vote's log row was written,
                         outside the lock. An edit that committed in between
                         moved [updated_at] past it, and the Board scan reads
                         [updated_at] as the newest change it has seen. The
                         vote-log replay on load applies the same rule. *)
                      let updated =
                        { post with
                          votes_up
                        ; votes_down
                        ; updated_at = Stdlib.Float.max post.updated_at ts
                        }
                      in
                      Hashtbl.replace store.posts post_key updated;
                      reindex_hot_post store ~previous:post ~updated:updated;
                      Hashtbl.replace store.vote_log vote_key (direction, ts);
                      mark_dirty_post store post_key;
                      invalidate_post_caches store;
                      Ok (updated.votes_up - updated.votes_down))))

let current_vote_for_comment store ~voter ~comment_id
    : (vote_direction option, board_error) Result.t =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok agent ->
  match Comment_id.of_string comment_id with
  | Error e -> Error e
  | Ok cid ->
      with_persist_lock store @@ fun () ->
      let* () = Board_votes_source.require_readable store in
      with_lock store (fun () ->
        let comment_key = Comment_id.to_string cid in
        if not (Hashtbl.mem store.comments comment_key) then
          Error (Comment_not_found comment_id)
        else
          let vote_key =
            Board_vote_key.comment ~comment_id:cid ~voter:agent
            |> Board_vote_key.to_string
          in
          Ok (Option.map fst (Hashtbl.find_opt store.vote_log vote_key)))

(** Vote on a comment. Same write-ahead shape as {!vote}. *)
let vote_comment store ~voter ~comment_id ~direction : (int, board_error) Result.t =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok agent ->
  let voter = Agent_id.to_string agent in
  match Comment_id.of_string comment_id with
  | Error e -> Error e
  | Ok cid ->
      with_persist_lock store @@ fun () ->
      let* () = Board_votes_source.require_readable store in
      let comment_key = Comment_id.to_string cid in
      let vote_id = Board_vote_key.comment ~comment_id:cid ~voter:agent in
      let vote_key = Board_vote_key.to_string vote_id in
      let staged : (float, board_error) Result.t =
        with_lock store (fun () ->
          match Hashtbl.find_opt store.comments comment_key with
          | None -> Error (Comment_not_found comment_id)
          | Some _cmt ->
              let previous = Option.map fst (Hashtbl.find_opt store.vote_log vote_key) in
              match Board_vote_transition.decide ~previous ~direction with
              | Board_vote_transition.Already_cast ->
                  Error (Already_voted (Printf.sprintf "%s already voted %s on comment %s"
                    voter (vote_direction_to_string direction) comment_id))
              | Board_vote_transition.Cast _ -> Ok (Time_compat.now ()))
      in
      (match staged with
       | Error _ as e -> e
       | Ok ts ->
         append_admitted_vote store ~vote:vote_id ~direction ~ts (fun () ->
              with_lock store (fun () ->
                match Hashtbl.find_opt store.comments comment_key with
                | None -> Error (Comment_not_found comment_id)
                | Some cmt ->
                  let previous = Option.map fst (Hashtbl.find_opt store.vote_log vote_key) in
                  match Board_vote_transition.decide ~previous ~direction with
                  | Board_vote_transition.Already_cast ->
                      Error (Already_voted (Printf.sprintf "%s already voted %s on comment %s"
                        voter (vote_direction_to_string direction) comment_id))
                  | Board_vote_transition.Cast transition ->
                      let votes_up, votes_down =
                        Board_vote_transition.apply_counts transition
                          ~votes_up:cmt.votes_up ~votes_down:cmt.votes_down
                      in
                      let updated =
                        { cmt with votes_up; votes_down }
                      in
                      Hashtbl.replace store.comments comment_key updated;
                      Hashtbl.replace store.vote_log vote_key (direction, ts);
                      mark_dirty_comment store comment_key;
                      invalidate_comment_caches store;
                      Ok (updated.votes_up - updated.votes_down))))
