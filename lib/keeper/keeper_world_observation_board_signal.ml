(** See [keeper_world_observation_board_signal.mli] for the contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module Message_scope = Keeper_world_observation_message_scope

type match_result =
  { explicit_mention : bool
  ; matched_targets : string list
  }

type board_observation_kind =
  | Observed_post_created
  | Observed_comment_added of Board_dispatch.board_comment_identity
  | Observed_reaction_changed of Board_dispatch.board_reaction_change
  | Observed_vote_cast of Board_dispatch.board_vote_change

type board_observation =
  { kind : board_observation_kind
  ; post_id : string
  ; author : string
  ; title : string
  ; content : string
  ; hearth : string option
  ; updated_at : float option
  }

type board_read_operation =
  | Get_post
  | Get_comments
  | Parse_queued_comment_identity

type board_unavailable =
  { operation : board_read_operation
  ; post_id : string
  ; error : Board.board_error
  }

type 'a board_read =
  | Available of 'a
  | Unavailable of board_unavailable

type replies_after_own_comment =
  { comment_offset : int
  ; oldest : Board.Comment_id.t
  ; newer : Board.Comment_id.t list
  }

type comment_state =
  [ `Never
  | `No_new_external
  | `New_external of replies_after_own_comment * string * string
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
    (* Not reachable from [get_post]/[get_comments] today (only write paths
       produce it). Classified [Permanent] for exhaustiveness: it signals
       the input itself fails a business rule, which retrying does not
       change. *)
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
  | Parse_queued_comment_identity -> "parse_queued_comment_identity"
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

let board_vote_target_of_queue = function
  | Keeper_event_queue.Vote_on_post post_id -> Board_dispatch.Vote_on_post post_id
  | Keeper_event_queue.Vote_on_comment comment_id ->
    Board_dispatch.Vote_on_comment comment_id
;;

let board_vote_direction_of_queue = function
  | Keeper_event_queue.Vote_up -> Board.Up
  | Keeper_event_queue.Vote_down -> Board.Down
;;

let board_vote_change_of_queue (vote : Keeper_event_queue.board_vote_change)
  : Board_dispatch.board_vote_change
  =
  { target = board_vote_target_of_queue vote.target
  ; target_author = vote.target_author
  ; voter = vote.voter
  ; direction = board_vote_direction_of_queue vote.direction
  }
;;

let queue_vote_target_of_board = function
  | Board_dispatch.Vote_on_post post_id -> Keeper_event_queue.Vote_on_post post_id
  | Board_dispatch.Vote_on_comment comment_id ->
    Keeper_event_queue.Vote_on_comment comment_id
;;

let queue_vote_direction_of_board = function
  | Board.Up -> Keeper_event_queue.Vote_up
  | Board.Down -> Keeper_event_queue.Vote_down
;;

let queue_vote_change_of_board (vote : Board_dispatch.board_vote_change)
  : Keeper_event_queue.board_vote_change
  =
  { target = queue_vote_target_of_board vote.target
  ; target_author = vote.target_author
  ; voter = vote.voter
  ; direction = queue_vote_direction_of_board vote.direction
  }
;;

let board_stimulus_of_board_signal (signal : Board_dispatch.board_signal) =
  { Keeper_event_queue.kind =
      (match signal.kind with
       | Board_dispatch.Board_post_created -> Keeper_event_queue.Post_created
       | Board_dispatch.Board_comment_added comment ->
         Keeper_event_queue.Comment_added
           { comment_id = Board.Comment_id.to_string comment.comment_id
           ; parent_id = Option.map Board.Comment_id.to_string comment.parent_id
           }
       | Board_dispatch.Board_reaction_changed reaction ->
         Keeper_event_queue.Reaction_changed
           (queue_reaction_change_of_board reaction)
       | Board_dispatch.Board_vote_cast vote ->
         Keeper_event_queue.Vote_cast (queue_vote_change_of_board vote))
  ; author = signal.author
  ; title = signal.title
  ; content = signal.content
  ; hearth = signal.hearth
  ; updated_at = signal.updated_at
  }
;;

(* The queue keeps the comment identity as its wire string (the queue is a
   leaf and cannot depend on Board). This is the boundary where it becomes
   the typed identity the Board store issued, parsed once; an identity that
   does not parse is a Board read that failed, reported like the others. *)
let board_observation_of_board_stimulus
      ~(post_id : string)
      (bs : Keeper_event_queue.board_stimulus)
  : (board_observation, board_unavailable) result
  =
  let ( let* ) = Result.bind in
  let parse_comment_id raw =
    Board.Comment_id.of_string raw
    |> Result.map_error (fun error ->
      { operation = Parse_queued_comment_identity; post_id; error })
  in
  let* kind =
    match bs.kind with
    | Keeper_event_queue.Post_created -> Ok Observed_post_created
    | Keeper_event_queue.Comment_added { comment_id; parent_id } ->
      let* comment_id = parse_comment_id comment_id in
      let* parent_id =
        match parent_id with
        | None -> Ok None
        | Some raw -> Result.map Option.some (parse_comment_id raw)
      in
      Ok (Observed_comment_added { Board_dispatch.comment_id; parent_id })
    | Keeper_event_queue.Reaction_changed reaction ->
      Ok (Observed_reaction_changed (board_reaction_change_of_queue reaction))
    | Keeper_event_queue.Vote_cast vote ->
      Ok (Observed_vote_cast (board_vote_change_of_queue vote))
  in
  Ok
    { kind
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

let address_text (signal : Board_dispatch.board_signal) =
  match signal.kind with
  | Board_dispatch.Board_post_created ->
    String.concat
      "\n"
      (List.filter
         (fun part -> not (String.equal (String.trim part) ""))
         [ signal.title; signal.content ])
  | Board_dispatch.Board_comment_added _ -> signal.content
  | Board_dispatch.Board_reaction_changed _ | Board_dispatch.Board_vote_cast _ -> ""
;;

let mention_ids_of_text text =
  Board.direct_targets_of_text text
  |> List.filter_map (fun target ->
    Board.Agent_id.to_string target |> Keeper_identity.Keeper_id.of_string)
  |> List.sort_uniq Keeper_identity.Keeper_id.compare
;;

let mention_ids_of_signal signal = mention_ids_of_text (address_text signal)

let address_text_of_observation observation =
  match observation.kind with
  | Observed_post_created ->
    String.concat
      "\n"
      (List.filter
         (fun part -> not (String.equal (String.trim part) ""))
         [ observation.title; observation.content ])
  | Observed_comment_added _ -> observation.content
  | Observed_reaction_changed _ | Observed_vote_cast _ -> ""
;;

let match_authored_text ~(meta : keeper_meta) ~author ~address_text =
  let self_ids = Message_scope.self_ids meta in
  if Message_scope.is_self_author ~self_ids author
  then { explicit_mention = false; matched_targets = [] }
  else (
    let targets =
      if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]
    in
    let mentions = mention_ids_of_text address_text in
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

let match_signal
      ~(meta : keeper_meta)
      ~(signal : Board_dispatch.board_signal)
  : match_result
  =
  match_authored_text ~meta ~author:signal.author ~address_text:(address_text signal)
;;

let match_observation ~(meta : keeper_meta) ~(observation : board_observation) =
  match_authored_text
    ~meta
    ~author:observation.author
    ~address_text:(address_text_of_observation observation)
;;

(** Check whether this keeper has commented on a post, and which comments
    came after the keeper's latest comment.
    Uses actual comment stream as ground truth (no proxy like reply_count
    or updated_at). A prior response is reconsidered only when a new external
    comment arrives.

    "After" is position in the thread as {!Board_dispatch.get_comments}
    returns it, the same order the thread read pages through, so
    [comment_offset] is an offset that read accepts and the replies are
    exactly the comments from there to the end of the thread. *)
let check_self_comment_status ~self_ids ~(post_id : string) : comment_status =
  match Board_dispatch.get_comments ~post_id with
  | Error error -> Unavailable { operation = Get_comments; post_id; error }
  | Ok comments ->
    let latest_own_offset =
      List.fold_left
        (fun (offset, latest_own) (c : Board.comment) ->
           let latest_own =
             if Message_scope.is_self_author
                  ~self_ids
                  (Board.Agent_id.to_string c.author)
             then Some offset
             else latest_own
           in
           offset + 1, latest_own)
        (0, None)
        comments
      |> snd
    in
    (match latest_own_offset with
     | None -> Available `Never
     | Some latest_own ->
       (match List.filteri (fun offset _ -> offset > latest_own) comments with
        | [] -> Available `No_new_external
        | oldest :: newer ->
          let newest =
            List.fold_left (fun (_ : Board.comment) (c : Board.comment) -> c) oldest newer
          in
          Available
            (`New_external
               ( { comment_offset = latest_own + 1
                 ; oldest = oldest.id
                 ; newer = List.map (fun (c : Board.comment) -> c.id) newer
                 }
               , Board.Agent_id.to_string newest.author
               , short_preview ~max_len:60 newest.content ))))
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
  | Comment_on_self_post
      (** An external comment arrived on a post the keeper authored. The
          reaction path already woke the author of the post it landed on; the
          comment path checked only whether the keeper had itself commented, so
          an answer to a keeper's own question did not reach it. *)
  | Thread_reply_after_self_comment
      (** A new external comment arrived on a post the keeper had commented on. *)
  | Reaction_after_self_activity
      (** An external reaction landed on a post the keeper authored or a thread
          the keeper had commented on. *)
  | Vote_on_self_post
      (** Someone else voted on a post the keeper authored. *)
  | Vote_on_self_comment
      (** Someone else voted on a comment the keeper authored. *)

let wake_reason_label = function
  | Explicit_mention -> "explicit_mention"
  | Broadcast -> "broadcast"
  | Comment_on_self_post -> "comment_on_self_post"
  | Thread_reply_after_self_comment -> "thread_reply_after_self_comment"
  | Reaction_after_self_activity -> "reaction_after_self_activity"
  | Vote_on_self_post -> "vote_on_self_post"
  | Vote_on_self_comment -> "vote_on_self_comment"
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
  | Board_dispatch.Board_post_created
  | Board_dispatch.Board_comment_added _
  | Board_dispatch.Board_vote_cast _ -> Available false
;;

(* A vote addresses exactly one lane: whoever wrote the voted-on post or
   comment. The producer read that author from the store when the vote landed
   and carries it in the payload, so no Board read happens here and the
   predicate cannot be [Unavailable]. The voter is [signal.author], and
   [route_for_keeper] has already ignored the signal for the voter's own
   lane, so a self-vote reaches no lane. *)
let vote_targets_self_writing ~self_ids (vote : Board_dispatch.board_vote_change) =
  if Message_scope.is_self_author ~self_ids vote.target_author
  then (
    match vote.target with
    | Board_dispatch.Vote_on_post _ -> Some Vote_on_self_post
    | Board_dispatch.Vote_on_comment _ -> Some Vote_on_self_comment)
  else None
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
    | Board_dispatch.Board_vote_cast vote ->
      Available (vote_targets_self_writing ~self_ids vote)
    | Board_dispatch.Board_comment_added _ ->
      (* Authorship first, the same order [reaction_touches_self_activity] uses
         above. Without it [check_self_comment_status] answers [`Never] for the
         author of the post — it only looks for the keeper's own comments — so
         an answer to a keeper's question never reached the keeper that asked.
         Measured on the live Board: 72 of 98 external comments on Keeper posts
         did not wake the poster, including a post whose title addressed the
         replier by name. *)
      (match self_authored_post ~self_ids ~post_id:signal.post_id with
       | Unavailable _ as unavailable -> unavailable
       | Available true -> Available (Some Comment_on_self_post)
       | Available false ->
         (match check_self_comment_status ~self_ids ~post_id:signal.post_id with
          | Unavailable _ as unavailable -> unavailable
          | Available (`New_external _) ->
            Available (Some Thread_reply_after_self_comment)
          | Available (`Never | `No_new_external) -> Available None))
    | Board_dispatch.Board_post_created -> Available None)
;;
