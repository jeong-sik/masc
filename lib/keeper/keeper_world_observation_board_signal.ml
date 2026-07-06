(** See [keeper_world_observation_board_signal.mli] for the contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module Message_scope = Keeper_world_observation_message_scope

type match_result =
  { explicit_mention : bool
  ; matched_targets : string list
  }

type comment_status =
  [ `Never
  | `No_new_external
  | `New_external of int * string * string
  | `Comment_read_error of string
  ]

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
       | Keeper_event_queue.Comment_added -> Board_dispatch.Board_comment_added)
  ; post_id
  ; author = bs.author
  ; title = bs.title
  ; content = bs.content
  ; mention_ids = List.filter_map Board.Mention_id.of_string bs.mention_ids
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
      ~continuity_summary:(_ : string)
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
    let mentions =
      signal.mention_ids
      |> List.filter_map (fun mention_id ->
        Keeper_identity.Keeper_id.of_string (Board.Mention_id.to_string mention_id))
    in
    let matched_targets =
      targets
      |> List.filter (fun target ->
        match Keeper_identity.Keeper_id.of_string target with
        | None -> false
        | Some target_id ->
          List.exists (Keeper_identity.Keeper_id.equal target_id) mentions)
    in
    if matched_targets <> []
    then { explicit_mention = true; matched_targets }
    else { explicit_mention = false; matched_targets = [] })
;;

(** Check whether this keeper has commented on a post, and whether new
    external comments arrived after the keeper's latest comment.
    Uses actual comment stream as ground truth (no proxy like reply_count
    or updated_at). Based on BDI commitment reconsideration: a committed
    response is only re-evaluated when new external beliefs arrive. *)
let check_self_comment_status ~self_ids ~(post_id : string) : comment_status =
  match Board_dispatch.get_comments ~post_id with
  | Error err ->
    `Comment_read_error
      ("board comments read failed while checking keeper self-comment status: "
       ^ Board.show_board_error err)
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
    match — is now unrepresentable rather than a string the consumer guesses at.
    [None] stays an [option] at the call site: it means the deterministic
    relevance pipeline examined the signal and found no reason for this keeper.
    Relatedness/proactive wake requires an explicit LLM/Fusion judgment boundary;
    local keyword scoring must not produce wake decisions. *)
type wake_reason =
  | Explicit_mention
      (** The signal mentions one of the keeper's identity targets. *)
  | Thread_reply_after_self_comment
      (** A new external comment arrived on a post the keeper had commented on. *)
  | Board_comment_read_error of string
      (** The comment stream could not be read, so the keeper is woken to observe
          the explicit failure instead of treating it as no prior participation. *)

let wake_reason_label = function
  | Explicit_mention -> "explicit_mention"
  | Thread_reply_after_self_comment -> "thread_reply_after_self_comment"
  | Board_comment_read_error _ -> "board_comment_read_error"
;;

let wake_reason
      ~continuity_summary
      ~(meta : keeper_meta)
      ~(signal : Board_dispatch.board_signal)
  : wake_reason option
  =
  let matched = match_signal ~continuity_summary ~meta ~signal in
  if matched.explicit_mention
  then Some Explicit_mention
  else (
    let self_ids = Message_scope.self_ids meta in
    match signal.kind with
    | Board_dispatch.Board_comment_added ->
      (match check_self_comment_status ~self_ids ~post_id:signal.post_id with
       | `New_external _ -> Some Thread_reply_after_self_comment
       | `Comment_read_error error -> Some (Board_comment_read_error error)
       | `Never | `No_new_external -> None)
    | Board_dispatch.Board_post_created -> None)
;;
