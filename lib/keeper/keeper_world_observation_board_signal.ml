(** See [keeper_world_observation_board_signal.mli] for the contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module Message_scope = Keeper_world_observation_message_scope

type match_result =
  { explicit_mention : bool
  ; matched_targets : string list
  ; score : int
  }

type comment_status = [ `Never | `No_new_external | `New_external of int * string * string ]

let board_reaction_target_of_queue = function
  | Keeper_event_queue.Reaction_post -> Board.Reaction_post
  | Keeper_event_queue.Reaction_comment -> Board.Reaction_comment
;;

let board_reaction_change_of_queue
      (reaction : Keeper_event_queue.board_reaction_change)
  : Board_dispatch.board_reaction_change
  =
  { target_type = board_reaction_target_of_queue reaction.target_type
  ; target_id = reaction.target_id
  ; user_id = reaction.user_id
  ; emoji = reaction.emoji
  ; reacted = reaction.reacted
  }
;;

(* RFC-0020: board signals are carried as a typed [Keeper_event_queue.board_stimulus]
   end-to-end. This total conversion rebuilds the [Board_dispatch.board_signal]
   the downstream matchers expect from the typed payload, taking the board post
   id from the enclosing stimulus. Replaces the prior JSON re-parse of a string
   payload (which could fail and silently drop signals). *)
let board_signal_of_board_stimulus
      ~(post_id : string)
      (bs : Keeper_event_queue.board_stimulus)
  : Board_dispatch.board_signal
  =
  { Board_dispatch.kind =
      (match bs.kind with
       | Keeper_event_queue.Post_created -> Board_dispatch.Board_post_created
       | Keeper_event_queue.Comment_added -> Board_dispatch.Board_comment_added
       | Keeper_event_queue.Reaction_changed reaction ->
         Board_dispatch.Board_reaction_changed (board_reaction_change_of_queue reaction))
  ; post_id
  ; author = bs.author
  ; title = bs.title
  ; content = bs.content
  ; hearth = bs.hearth
  ; updated_at = bs.updated_at
  }
;;

let post_id_string (post : Board.post) = Board.Post_id.to_string post.id

let compare_cursor_token (ts_a, post_id_a) (ts_b, post_id_b) =
  let cmp = Float.compare ts_a ts_b in
  if cmp <> 0 then cmp else String.compare post_id_a post_id_b
;;

let cursor_token_of_post (post : Board.post) = post.updated_at, post_id_string post

let list_posts_after_cursor (cursor_ts, cursor_post_id) =
  let cursor_post_id = Option.value ~default:"" cursor_post_id in
  let is_after_cursor post =
    compare_cursor_token (cursor_token_of_post post) (cursor_ts, cursor_post_id) > 0
  in
  Board_dispatch.list_posts ~sort_by:Board_dispatch.Updated ~limit:max_int ()
  |> List.filter is_after_cursor
  |> List.sort (fun (a : Board.post) (b : Board.post) ->
    compare_cursor_token (cursor_token_of_post a) (cursor_token_of_post b))
;;

let text (signal : Board_dispatch.board_signal) =
  String.concat
    "\n"
    (List.filter
       (fun part -> String.trim part <> "")
       [ signal.title
       ; signal.content
       ; (match signal.hearth with
          | Some hearth -> hearth
          | None -> "")
       ])
;;

let match_signal
      ~(meta : keeper_meta)
      ~(signal : Board_dispatch.board_signal)
  : match_result
  =
  let self_ids = Message_scope.self_ids meta in
  if Message_scope.is_self_author ~self_ids signal.author
  then { explicit_mention = false; matched_targets = []; score = 0 }
  else (
    let targets =
      if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]
    in
    let haystack = String.lowercase_ascii (text signal) in
    let matched_targets =
      targets
      |> List.filter (fun target ->
        let needle = "@" ^ String.lowercase_ascii (String.trim target) in
        needle <> "@" && String_util.contains_substring haystack needle)
    in
    if matched_targets <> []
    then { explicit_mention = true; matched_targets; score = 100 }
    else { explicit_mention = false; matched_targets = []; score = 0 })
;;

(** Check whether this keeper has commented on a post, and whether new
    external comments arrived after the keeper's latest comment.
    Uses actual comment stream as ground truth (no proxy like reply_count
    or updated_at). A prior response is reconsidered only when a new external
    comment arrives. *)
let check_self_comment_status ~self_ids ~(post_id : string) : comment_status =
  match Board_dispatch.get_comments ~post_id with
  | Error _ -> `Never
  | Ok comments ->
    let my_comments =
      List.filter
        (fun (c : Board.comment) ->
           Message_scope.is_self_author
             ~self_ids
             (Board.Agent_id.to_string c.author))
        comments
    in
    if my_comments = []
    then `Never
    else (
      let my_latest_ts =
        List.fold_left
          (fun acc (c : Board.comment) -> max acc c.created_at)
          0.0
          my_comments
      in
      let external_after =
        List.filter
          (fun (c : Board.comment) ->
             (not
                (Message_scope.is_self_author
                   ~self_ids
                   (Board.Agent_id.to_string c.author)))
             && c.created_at > my_latest_ts)
          comments
      in
      match external_after with
      | [] -> `No_new_external
      | hd :: tl ->
        let latest =
          List.fold_left
            (fun (acc : Board.comment) (c : Board.comment) ->
               if c.created_at > acc.created_at then c else acc)
            hd
            tl
        in
        `New_external
          ( List.length external_after
          , Board.Agent_id.to_string latest.author
          , short_preview ~max_len:60 latest.content ))
;;

(** Why a keeper woke for a board signal. Closed set replacing the prior
    [string option] producer/consumer contract (RFC-0020): the matchers in
    {!wake_reason} are the only producers, so a reason no matcher emits — e.g.
    the previously dead ["board_activity"] generic bucket the consumer used to
    match — is now unrepresentable rather than a string the consumer guesses
    at. [None] stays an [option] at the call site: it means the structural
    reactive pipeline examined the signal and found no deterministic address for
    this keeper. Semantic relatedness is intentionally not represented here: it
    requires an LLM/Judge attention boundary, not goal-keyword matching in the
    board publish hook. *)
type wake_reason =
  | Explicit_mention
      (** The signal mentions one of the keeper's identity targets. *)
  | Thread_reply_after_self_comment
      (** A new external comment arrived on a post the keeper had commented on. *)
  | Reaction_after_self_activity
      (** An external reaction landed on a post the keeper authored or a thread
          the keeper had commented on. *)

let wake_reason_label = function
  | Explicit_mention -> "explicit_mention"
  | Thread_reply_after_self_comment -> "thread_reply_after_self_comment"
  | Reaction_after_self_activity -> "reaction_after_self_activity"
;;

let self_authored_post ~self_ids ~(post_id : string) =
  match Board_dispatch.get_post ~post_id with
  | Error _ -> false
  | Ok post ->
    Message_scope.is_self_author ~self_ids (Board.Agent_id.to_string post.author)
;;

(* TEL-OK: pure wake predicate; board persistence and keeper wake execution own
   telemetry at their action boundaries. *)
let reaction_touches_self_activity ~self_ids ~(signal : Board_dispatch.board_signal) =
  match signal.kind with
  | Board_dispatch.Board_reaction_changed _ ->
    (not (Message_scope.is_self_author ~self_ids signal.author))
    &&
    (self_authored_post ~self_ids ~post_id:signal.post_id
     ||
     match check_self_comment_status ~self_ids ~post_id:signal.post_id with
     | `Never -> false
     | `No_new_external | `New_external _ -> true)
  | Board_dispatch.Board_post_created | Board_dispatch.Board_comment_added -> false
;;

let wake_reason
      ~(meta : keeper_meta)
      ~(signal : Board_dispatch.board_signal)
  : wake_reason option
  =
  let matched = match_signal ~meta ~signal in
  if matched.explicit_mention
  then Some Explicit_mention
  else (
    let self_ids = Message_scope.self_ids meta in
    match signal.kind with
    | Board_dispatch.Board_reaction_changed _ ->
      if reaction_touches_self_activity ~self_ids ~signal
      then Some Reaction_after_self_activity
      else None
    | Board_dispatch.Board_comment_added ->
      (match check_self_comment_status ~self_ids ~post_id:signal.post_id with
       | `New_external _ -> Some Thread_reply_after_self_comment
       | `Never | `No_new_external -> None)
    | Board_dispatch.Board_post_created -> None)
;;
