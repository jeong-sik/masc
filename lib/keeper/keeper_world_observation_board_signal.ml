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
  | Get_post_and_comments

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

(* Board-unavailable disposition: whether a failed board read is worth
   retrying. Closed set so a new [Board.board_error] variant forces a
   classification decision here rather than defaulting to either
   "retry forever" (the old crash-loop bug: [Post_not_found] modeled as
   transient) or "silently drop" (would swallow a real transient hiccup). *)
type disposition =
  | Permanent
      (** Retrying the same read produces the same error. Callers must
          consume/drop the stimulus and must not requeue it. *)
  | Transient
      (** An environment-level hiccup unrelated to whether the post/comment
          exists. Callers may retain the stimulus for a later cycle. *)

let disposition_of_error : Board.board_error -> disposition = function
  | Board.Post_not_found _ ->
    (* The post was deleted or swept from the store. Post ids are
       cryptographically random (never reused), so this never resolves on
       retry — the dominant real-world cause of the crash-loop this type
       replaces (masc keeper cycle exception incident, board post swept
       from the in-memory store). *)
    Permanent
  | Board.Comment_not_found _ ->
    (* Same permanence argument as [Post_not_found], for a comment id. *)
    Permanent
  | Board.Invalid_id _ ->
    (* The id string embedded in the stimulus is malformed. Retrying with
       the same string reproduces the same validation failure. *)
    Permanent
  | Board.Io_error _ ->
    (* Store/disk-level hiccup unrelated to whether the target exists; the
       next read is expected to succeed once the environment recovers. *)
    Transient
  | Board.Validation_error _ ->
    (* Not reachable from Board read paths today (only write paths produce it).
       Classified [Permanent] for exhaustiveness: it signals the input itself
       fails a business rule, which retrying does not change. *)
    Permanent
  | Board.Already_voted _ ->
    (* Not reachable from a read path. Classified [Permanent]: it names an
       already-settled action conflict, not a timing issue that retry
       resolves. *)
    Permanent
  | Board.Already_exists _ ->
    (* Not reachable from a read path. Same deterministic-conflict
       reasoning as [Already_voted]. *)
    Permanent
  | Board.Unauthorized _ ->
    (* Not reachable from a read path. An identity/ownership gate rejection
       is deterministic and does not resolve by retrying. *)
    Permanent
;;

let disposition_of_unavailable (unavailable : board_unavailable) =
  disposition_of_error unavailable.error
;;

let board_read_operation_to_string = function
  | Get_post -> "get_post"
  | Get_comments -> "get_comments"
  | Get_post_and_comments -> "get_post_and_comments"
;;

let unavailable_to_string unavailable =
  Printf.sprintf
    "%s unavailable for post %s: %s"
    (board_read_operation_to_string unavailable.operation)
    unavailable.post_id
    (Board.show_board_error unavailable.error)
;;

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

let compare_cursor_token = Board.compare_post_cursor_token

let cursor_token_of_post (post : Board.post) = post.updated_at, post_id_string post

let list_post_thread_snapshots_after_cursor (cursor_ts, cursor_post_id) =
  let cursor_post_id = Option.value ~default:"" cursor_post_id in
  Board_dispatch.list_post_thread_snapshots_after_cursor
    ~after:(cursor_ts, cursor_post_id)
    ~limit:Board.Limits.cursor_snapshot_batch_size
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

let address_text (signal : Board_dispatch.board_signal) =
  match signal.kind with
  | Board_dispatch.Board_post_created ->
    String.concat
      "\n"
      (List.filter
         (fun part -> not (String.equal (String.trim part) ""))
         [ signal.title; signal.content ])
  | Board_dispatch.Board_comment_added -> signal.content
  | Board_dispatch.Board_reaction_changed _ -> ""
;;

let mention_ids_of_signal signal =
  Board.direct_targets_of_text (address_text signal)
  |> List.filter_map (fun target ->
    Board.Agent_id.to_string target |> Keeper_identity.Keeper_id.of_string)
  |> List.sort_uniq Keeper_identity.Keeper_id.compare
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

(** Whether this keeper has taken part in a thread, and whether new external
    comments arrived after it last spoke.

    Participation is authoring the post OR commenting on it. Counting only
    comments left a post's own author out of its own thread: a keeper that
    raised a blocker as a post was never woken by the reply, because
    {!wake_reason} routes the [Thread_participants] audience through here and
    an author with no comments of its own scored [`Never]. The reaction path
    ({!reaction_touches_self_activity}) already treated post authorship as self
    activity; this applies the same rule to comments.

    The post record and the comment stream are the ground truth (no proxy like
    reply_count or updated_at). A prior response is reconsidered only when a new
    external comment arrives after the keeper's own latest contribution, where a
    contribution now includes writing the post. *)
let thread_status_of_snapshot ~self_ids ~(post : Board.post) ~(comments : Board.comment list) =
  let is_self_comment (c : Board.comment) =
    Message_scope.is_self_author ~self_ids (Board.Agent_id.to_string c.author)
  in
  let self_post_ts =
    if Message_scope.is_self_author
         ~self_ids
         (Board.Agent_id.to_string post.author)
    then Some post.created_at
    else None
  in
  (* The keeper's own latest contribution to this thread: the post it wrote,
     its newest comment, or whichever of the two is later. [None] IS
     non-participation, so there is no seed timestamp to pick and no state
     where a missing contribution reads as one at epoch zero. *)
  let my_latest_contribution =
    List.fold_left
      (fun acc (c : Board.comment) ->
         match acc with
         | None -> Some c.created_at
         | Some latest -> Some (Float.max latest c.created_at))
      self_post_ts
      (List.filter is_self_comment comments)
  in
  match my_latest_contribution with
  | None -> `Never
  | Some my_latest_ts ->
    let external_after =
      List.filter
        (fun (c : Board.comment) ->
           (not (is_self_comment c)) && c.created_at > my_latest_ts)
        comments
    in
    (match external_after with
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

type thread_snapshot =
  { post : Board.post
  ; status : comment_state
  }

let read_self_thread_snapshot ~self_ids ~(post_id : string) : thread_snapshot board_read =
  match Board_dispatch.get_post_and_comments ~post_id () with
  | Error error ->
    Unavailable { operation = Get_post_and_comments; post_id; error }
  | Ok (post, comments) ->
    Available { post; status = thread_status_of_snapshot ~self_ids ~post ~comments }
;;

let check_self_thread_status ~self_ids ~(post_id : string) : comment_status =
  match read_self_thread_snapshot ~self_ids ~post_id with
  | Unavailable _ as unavailable -> unavailable
  | Available snapshot -> Available snapshot.status
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
  | Broadcast
      (** The exact [@@all] Keeper Board address selected every non-author
          lane. *)
  | Thread_reply_after_self_activity
      (** A new external comment arrived after the keeper authored the post or
          commented on it. *)
  | Reaction_after_self_activity
      (** An external reaction landed after the keeper authored the post or
          commented on it. *)

let wake_reason_label = function
  | Explicit_mention -> "explicit_mention"
  | Broadcast -> "broadcast"
  | Thread_reply_after_self_activity -> "thread_reply_after_self_activity"
  | Reaction_after_self_activity -> "reaction_after_self_activity"
;;

(* TEL-OK: pure wake predicate; board persistence and keeper wake execution own
   telemetry at their action boundaries. *)
let reaction_touches_self_activity ~self_ids ~(signal : Board_dispatch.board_signal) =
  match signal.kind with
  | Board_dispatch.Board_reaction_changed _ ->
    if Message_scope.is_self_author ~self_ids signal.author
    then Available false
    else (
      (* [check_self_thread_status] now folds post authorship into
         participation, so the separate post-authorship probe this branch
         used to run first is redundant: authoring the post no longer scores
         [`Never]. One definition of "did I take part in this thread", not
         two. *)
      match check_self_thread_status ~self_ids ~post_id:signal.post_id with
      | Unavailable _ as unavailable -> unavailable
      | Available `Never -> Available false
      | Available (`No_new_external | `New_external _) -> Available true)
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
      (match check_self_thread_status ~self_ids ~post_id:signal.post_id with
       | Unavailable _ as unavailable -> unavailable
       | Available (`New_external _) -> Available (Some Thread_reply_after_self_activity)
       | Available (`Never | `No_new_external) -> Available None)
    | Board_dispatch.Board_post_created -> Available None)
;;
