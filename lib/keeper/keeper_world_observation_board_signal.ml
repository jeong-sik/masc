(** See [keeper_world_observation_board_signal.mli] for the contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module Message_scope = Keeper_world_observation_message_scope

let ( let* ) = Result.bind

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

type board_evidence =
  { post : Board.post
  ; comments : Board.comment list
  }

type board_stimulus_materialization_error =
  | Source_unavailable of board_unavailable
  | Post_identity_mismatch of {
      signal_post_id : string;
      snapshot_post_id : string;
    }
  | Invalid_snapshot of Keeper_event_queue.board_stimulus_error

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
;;

let unavailable_to_string unavailable =
  Printf.sprintf
    "%s unavailable for post %s: %s"
    (board_read_operation_to_string unavailable.operation)
    unavailable.post_id
    (Board.show_board_error unavailable.error)
;;

let materialization_error_to_string = function
  | Source_unavailable unavailable -> unavailable_to_string unavailable
  | Post_identity_mismatch { signal_post_id; snapshot_post_id } ->
    Printf.sprintf
      "Board signal post id %s does not match evidence post id %s"
      signal_post_id
      snapshot_post_id
  | Invalid_snapshot error -> Keeper_event_queue.board_stimulus_error_to_string error
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
  ; updated_at = Some bs.updated_at
  }
;;

let post_id_string (post : Board.post) = Board.Post_id.to_string post.id

let compare_cursor_token (ts_a, post_id_a) (ts_b, post_id_b) =
  Keeper_reaction_store.compare_normalized_cursor
    { cursor_ts = ts_a; post_id = Some post_id_a }
    { cursor_ts = ts_b; post_id = Some post_id_b }
;;

let normalize_cursor_token (cursor_ts, post_id) =
  Keeper_reaction_store.normalize_cursor
    { Keeper_reaction_store.cursor_ts; post_id }
;;

let cursor_token_of_post (post : Board.post) =
  let* cursor =
    normalize_cursor_token (post.updated_at, Some (post_id_string post))
  in
  match cursor.Keeper_reaction_store.post_id with
  | Some post_id -> Ok (cursor.cursor_ts, post_id)
  | None ->
    Error
      (Keeper_reaction_store.Integrity_failure
         "normalized Board post cursor lost its post id")
;;

let list_posts_after_cursor (cursor_ts, cursor_post_id) =
  let* cursor = normalize_cursor_token (cursor_ts, cursor_post_id) in
  let base_token =
    cursor.cursor_ts, Option.value ~default:"" cursor.post_id
  in
  let rec attach_tokens reversed = function
    | [] -> Ok reversed
    | post :: rest ->
      let* token = cursor_token_of_post post in
      attach_tokens ((token, post) :: reversed) rest
  in
  let posts = Board_dispatch.list_posts ~sort_by:Board_dispatch.Updated ~limit:max_int () in
  let* with_tokens = attach_tokens [] posts in
  Ok
    (with_tokens
     |> List.filter (fun (token, _) -> compare_cursor_token token base_token > 0)
     |> List.sort (fun (left, _) (right, _) -> compare_cursor_token left right)
     |> List.map snd)
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
let comment_state_of_comments ~self_ids comments : comment_state =
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

let check_self_comment_status ~self_ids ~(post_id : string) : comment_status =
  match Board_dispatch.get_comments ~post_id with
  | Error error -> Unavailable { operation = Get_comments; post_id; error }
  | Ok comments -> Available (comment_state_of_comments ~self_ids comments)
;;

let queue_post_kind_of_board = function
  | Board.Human_post -> Keeper_event_queue.Human_post
  | Board.Automation_post -> Keeper_event_queue.Automation_post
  | Board.System_post -> Keeper_event_queue.System_post
;;

let board_stimulus_of_projection
      ~(signal : Board_dispatch.board_signal)
      ~title
      ~preview
      ~hearth
      ~post_kind
      ~updated_at
      ~explicit_mention
      ~matched_targets
      ~thread_snapshot
  =
  let board =
    { Keeper_event_queue.kind =
        (match signal.kind with
         | Board_dispatch.Board_post_created -> Keeper_event_queue.Post_created
         | Board_dispatch.Board_comment_added -> Keeper_event_queue.Comment_added
         | Board_dispatch.Board_reaction_changed reaction ->
           Keeper_event_queue.Reaction_changed
             (queue_reaction_change_of_board reaction))
    ; author = signal.author
    ; title
    ; content = signal.content
    ; preview
    ; hearth
    ; post_kind = queue_post_kind_of_board post_kind
    ; updated_at
    ; explicit_mention
    ; matched_targets
    ; thread_snapshot
    }
  in
  Keeper_event_queue.validate_board_stimulus board
  |> Result.map (fun () -> board)
  |> Result.map_error (fun error -> Invalid_snapshot error)
;;

let thread_snapshot_of_evidence
      ~self_ids
      ~(signal : Board_dispatch.board_signal)
      comments
  =
  let latest_external latest_author latest_preview =
    Some { Keeper_event_queue.latest_author = latest_author; latest_preview }
  in
  match signal.kind with
  | Board_dispatch.Board_post_created ->
    { Keeper_event_queue.self_commented = false
    ; new_external_since = 0
    ; latest_external = None
    }
  | Board_dispatch.Board_comment_added ->
    (match comment_state_of_comments ~self_ids comments with
     | `Never ->
       { Keeper_event_queue.self_commented = false
       ; new_external_since = 1
       ; latest_external =
           latest_external signal.author (short_preview ~max_len:60 signal.content)
       }
     | `No_new_external ->
       { Keeper_event_queue.self_commented = true
       ; new_external_since = 0
       ; latest_external =
           latest_external signal.author (short_preview ~max_len:60 signal.content)
       }
     | `New_external (count, author, preview) ->
       { Keeper_event_queue.self_commented = true
       ; new_external_since = count
       ; latest_external = latest_external author preview
       })
  | Board_dispatch.Board_reaction_changed _ ->
    let self_commented =
      match comment_state_of_comments ~self_ids comments with
      | `Never -> false
      | `No_new_external | `New_external _ -> true
    in
    { Keeper_event_queue.self_commented
    ; new_external_since = 0
    ; latest_external = None
    }
;;

let board_stimulus_of_board_evidence
      ~(meta : keeper_meta)
      ~(signal : Board_dispatch.board_signal)
      ~(post : Board.post)
      ~(comments : Board.comment list)
  =
  let snapshot_post_id = Board.Post_id.to_string post.id in
  if not (String.equal signal.post_id snapshot_post_id)
  then Error (Post_identity_mismatch { signal_post_id = signal.post_id; snapshot_post_id })
  else
    let matched = match_signal ~meta ~signal in
    board_stimulus_of_projection
      ~signal
      ~title:post.title
      ~preview:(short_preview ~max_len:80 post.content)
      ~hearth:post.hearth
      ~post_kind:post.post_kind
      ~updated_at:post.updated_at
      ~explicit_mention:matched.explicit_mention
      ~matched_targets:matched.matched_targets
      ~thread_snapshot:
        (thread_snapshot_of_evidence
           ~self_ids:(Message_scope.self_ids meta)
           ~signal
           comments)
;;

let read_board_evidence (signal : Board_dispatch.board_signal) =
  match Board_dispatch.get_post ~post_id:signal.post_id with
  | Error error ->
    Unavailable { operation = Get_post; post_id = signal.post_id; error }
  | Ok post ->
    (match signal.kind with
     | Board_dispatch.Board_post_created ->
       Available { post; comments = [] }
     | Board_dispatch.Board_comment_added
     | Board_dispatch.Board_reaction_changed _ ->
       (match Board_dispatch.get_comments ~post_id:signal.post_id with
        | Error error ->
          Unavailable
            { operation = Get_comments; post_id = signal.post_id; error }
        | Ok comments -> Available { post; comments }))
;;

let materialize_board_stimulus ~(meta : keeper_meta) signal =
  match read_board_evidence signal with
  | Unavailable unavailable -> Error (Source_unavailable unavailable)
  | Available { post; comments } ->
    board_stimulus_of_board_evidence ~meta ~signal ~post ~comments
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

let wake_reason_of_board_evidence
      ~(meta : keeper_meta)
      ~(signal : Board_dispatch.board_signal)
      ({ post; comments } : board_evidence)
  =
  let matched = match_signal ~meta ~signal in
  if matched.explicit_mention
  then Some Explicit_mention
  else (
    let self_ids = Message_scope.self_ids meta in
    match signal.kind with
    | Board_dispatch.Board_post_created -> None
    | Board_dispatch.Board_comment_added ->
      (match comment_state_of_comments ~self_ids comments with
       | `New_external _ -> Some Thread_reply_after_self_comment
       | `Never | `No_new_external -> None)
    | Board_dispatch.Board_reaction_changed _ ->
      if Message_scope.is_self_author ~self_ids signal.author
      then None
      else if
        Message_scope.is_self_author
          ~self_ids
          (Board.Agent_id.to_string post.author)
      then Some Reaction_after_self_activity
      else
        (match comment_state_of_comments ~self_ids comments with
         | `Never -> None
         | `No_new_external | `New_external _ ->
           Some Reaction_after_self_activity))
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
