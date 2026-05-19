(** See [keeper_world_observation_board_signal.mli] for the contract. *)

open Keeper_types

module Message_scope = Keeper_world_observation_message_scope

type match_result =
  { explicit_mention : bool
  ; matched_targets : string list
  ; score : int
  }

type comment_status = [ `Never | `No_new_external | `New_external of int * string * string ]

let json_string_member name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | _ -> None
;;

let json_string_null_member name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | Some `Null | None -> None
  | _ -> None
;;

let json_float_null_member name fields =
  match List.assoc_opt name fields with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | Some `Null | None -> None
  | _ -> None
;;

let board_signal_kind_of_string = function
  | "post_created" | "post" -> Some Board_dispatch.Board_post_created
  | "comment_added" | "comment" -> Some Board_dispatch.Board_comment_added
  | _ -> None
;;

let of_stimulus_payload payload =
  try
    match Yojson.Safe.from_string payload with
    | `Assoc fields
      when Option.equal
             String.equal
             (json_string_member "source" fields)
             (Some "board_signal") ->
      (match
         ( json_string_member "kind" fields
         , json_string_member "post_id" fields
         , json_string_member "author" fields
         , json_string_member "title" fields
         , json_string_member "content" fields )
       with
       | Some kind, Some post_id, Some author, Some title, Some content ->
         Option.map
           (fun kind ->
              { Board_dispatch.kind
              ; post_id
              ; author
              ; title
              ; content
              ; hearth = json_string_null_member "hearth" fields
              ; updated_at = json_float_null_member "updated_at_unix" fields
              })
           (board_signal_kind_of_string kind)
       | _ -> None)
    | _ -> None
  with
  | Yojson.Json_error _ -> None
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

let text (signal : Board_dispatch.keeper_board_signal) =
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
      ~(signal : Board_dispatch.keeper_board_signal)
  : match_result
  =
  let self_tokens = Message_scope.self_identity_tokens meta in
  if Message_scope.is_self_author ~self_tokens signal.author
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
    or updated_at). Based on BDI commitment reconsideration: a committed
    response is only re-evaluated when new external beliefs arrive. *)
let check_self_comment_status ~self_tokens ~(post_id : string) : comment_status =
  match Board_dispatch.get_comments ~post_id with
  | Error _ -> `Never
  | Ok comments ->
    let my_comments =
      List.filter
        (fun (c : Board.comment) ->
           Message_scope.is_self_author
             ~self_tokens
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
                   ~self_tokens
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

type stigmergy_match_result = { overall_score : int }

let stigmergy_match ~(meta : keeper_meta) ~(signal : Board_dispatch.keeper_board_signal)
  : stigmergy_match_result
  =
  let signal_text = String.lowercase_ascii (text signal) in
  let goal_keywords =
    [ meta.goal; meta.short_goal; meta.mid_goal; meta.long_goal ]
    |> List.filter (fun s -> String.trim s <> "")
    |> List.concat_map (fun g ->
      String.split_on_char ' ' (String.lowercase_ascii g)
      |> List.map String.trim
      |> List.filter (fun s -> String.length s > 3))
    |> List.sort_uniq String.compare
  in
  let score =
    List.fold_left
      (fun acc kw -> if String_util.contains_substring signal_text kw then acc + 5 else acc)
      0
      goal_keywords
  in
  { overall_score = min score 50 }
;;

let wake_reason
      ~continuity_summary
      ~(meta : keeper_meta)
      ~(signal : Board_dispatch.keeper_board_signal)
  : string option
  =
  let matched = match_signal ~continuity_summary ~meta ~signal in
  if matched.explicit_mention
  then Some "explicit_mention"
  else if Message_scope.scope_message_feed_enabled meta
  then Some "board_activity"
  else (
    let stigmergy = stigmergy_match ~meta ~signal in
    if stigmergy.overall_score > 0
    then Some ("stigmergy: score=" ^ string_of_int stigmergy.overall_score)
    else (
      let self_tokens = Message_scope.self_identity_tokens meta in
      match signal.kind with
      | Board_dispatch.Board_comment_added ->
        (match check_self_comment_status ~self_tokens ~post_id:signal.post_id with
         | `New_external _ -> Some "thread_reply_after_self_comment"
         | `Never | `No_new_external -> None)
      | Board_dispatch.Board_post_created -> None))
;;
