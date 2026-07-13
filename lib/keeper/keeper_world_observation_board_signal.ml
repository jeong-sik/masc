(** See [keeper_world_observation_board_signal.mli] for the contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module Message_scope = Keeper_world_observation_message_scope

type match_result =
  { explicit_mention : bool
  ; matched_targets : string list
  }

type board_read_operation =
  | Get_post
  | Get_comments

type board_unavailable =
  { operation : board_read_operation
  ; post_id : string
  ; error : Board.board_error
  }

type 'a board_read =
  | Available of 'a
  | Unavailable of board_unavailable

type comment_state =
  [ `Never
  | `No_new_external
  | `New_external of int * string * string
  ]

type comment_status = comment_state board_read

exception Board_unavailable of board_unavailable

let board_read_operation_to_string = function
  | Get_post -> "get_post"
  | Get_comments -> "get_comments"
;;

let unavailable_to_string unavailable =
  Printf.sprintf
    "%s unavailable for post %s: %s"
    (board_read_operation_to_string unavailable.operation)
    unavailable.post_id
    (Board.show_board_error unavailable.error)
;;

let raise_unavailable unavailable = raise (Board_unavailable unavailable)

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

let queue_reaction_target_of_board = function
  | Board.Reaction_post -> Keeper_event_queue.Reaction_post
  | Board.Reaction_comment -> Keeper_event_queue.Reaction_comment
;;

let queue_reaction_change_of_board
      (reaction : Board_dispatch.board_reaction_change)
  : Keeper_event_queue.board_reaction_change
  =
  { target_type = queue_reaction_target_of_board reaction.target_type
  ; target_id = reaction.target_id
  ; user_id = reaction.user_id
  ; emoji = reaction.emoji
  ; reacted = reaction.reacted
  }
;;

let board_stimulus_of_board_signal (signal : Board_dispatch.board_signal) =
  { Keeper_event_queue.kind =
      (match signal.kind with
       | Board_dispatch.Board_post_created -> Keeper_event_queue.Post_created
       | Board_dispatch.Board_comment_added -> Keeper_event_queue.Comment_added
       | Board_dispatch.Board_reaction_changed reaction ->
         Keeper_event_queue.Reaction_changed
           (queue_reaction_change_of_board reaction))
  ; author = signal.author
  ; title = signal.title
  ; content = signal.content
  ; hearth = signal.hearth
  ; updated_at = signal.updated_at
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

let mention_ids_of_signal signal =
  (* Board dispatch still carries textual Board content. Convert that boundary
     payload exactly once into canonical Keeper ids and compare only those typed
     identities below. This deliberately replaces substring matching; tokens
     such as [@foo-extra] and [email@foo.example] cannot address [foo]. *)
  Keeper_lane_mentions.mention_ids_of_content (text signal)
;;

let match_signal
      ~(meta : keeper_meta)
      ~(signal : Board_dispatch.board_signal)
  : match_result
  =
  let self_ids = Message_scope.self_ids meta in
  if Message_scope.is_self_author ~self_ids signal.author
  then { explicit_mention = false; matched_targets = [] }
  else (
    let targets =
      if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]
    in
    let mentions = mention_ids_of_signal signal in
    let matched_targets =
      targets
      |> List.filter (fun target ->
        match Keeper_identity.Keeper_id.of_string target with
        | None -> false
        | Some target_id ->
          List.exists
            (Keeper_identity.Keeper_id.equal target_id)
            mentions)
    in
    if matched_targets <> []
    then { explicit_mention = true; matched_targets }
    else { explicit_mention = false; matched_targets = [] })
;;

(** Check whether this keeper has commented on a post, and whether new
    external comments arrived after the keeper's latest comment.
    Uses actual comment stream as ground truth (no proxy like reply_count
    or updated_at). A prior response is reconsidered only when a new external
    comment arrives. *)
let check_self_comment_status ~self_ids ~(post_id : string) : comment_status =
  match Board_dispatch.get_comments ~post_id with
  | Error error -> Unavailable { operation = Get_comments; post_id; error }
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
    then Available `Never
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
      | [] -> Available `No_new_external
      | hd :: tl ->
        let latest =
          List.fold_left
            (fun (acc : Board.comment) (c : Board.comment) ->
               if c.created_at > acc.created_at then c else acc)
            hd
            tl
        in
        Available
          (`New_external
             ( List.length external_after
             , Board.Agent_id.to_string latest.author
             , short_preview ~max_len:60 latest.content )))
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
  | Error error -> Unavailable { operation = Get_post; post_id; error }
  | Ok post ->
    Available
      (Message_scope.is_self_author ~self_ids (Board.Agent_id.to_string post.author))
;;

(* TEL-OK: pure wake predicate; board persistence and keeper wake execution own
   telemetry at their action boundaries. *)
let reaction_touches_self_activity ~self_ids ~(signal : Board_dispatch.board_signal) =
  match signal.kind with
  | Board_dispatch.Board_reaction_changed _ ->
    if Message_scope.is_self_author ~self_ids signal.author
    then Available false
    else (
      match self_authored_post ~self_ids ~post_id:signal.post_id with
      | Unavailable _ as unavailable -> unavailable
      | Available true -> Available true
      | Available false ->
        (match check_self_comment_status ~self_ids ~post_id:signal.post_id with
         | Unavailable _ as unavailable -> unavailable
         | Available `Never -> Available false
         | Available (`No_new_external | `New_external _) -> Available true))
  | Board_dispatch.Board_post_created | Board_dispatch.Board_comment_added ->
    Available false
;;

let wake_reason
      ~(meta : keeper_meta)
      ~(signal : Board_dispatch.board_signal)
  : wake_reason option board_read
  =
  let matched = match_signal ~meta ~signal in
  if matched.explicit_mention
  then Available (Some Explicit_mention)
  else (
    let self_ids = Message_scope.self_ids meta in
    match signal.kind with
    | Board_dispatch.Board_reaction_changed _ ->
      (match reaction_touches_self_activity ~self_ids ~signal with
       | Unavailable _ as unavailable -> unavailable
       | Available true -> Available (Some Reaction_after_self_activity)
       | Available false -> Available None)
    | Board_dispatch.Board_comment_added ->
      (match check_self_comment_status ~self_ids ~post_id:signal.post_id with
       | Unavailable _ as unavailable -> unavailable
       | Available (`New_external _) -> Available (Some Thread_reply_after_self_comment)
       | Available (`Never | `No_new_external) -> Available None)
    | Board_dispatch.Board_post_created -> Available None)
;;
