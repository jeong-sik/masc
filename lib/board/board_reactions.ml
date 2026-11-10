open Board_core_persist
open Result.Syntax

let normalize_reaction_emoji raw =
  let emoji = String.trim raw in
  if List.exists (String.equal emoji) board_reaction_emojis
  then Ok emoji
  else
    Error (Validation_error (Printf.sprintf "Unsupported board reaction emoji: %s" emoji))
;;

let canonical_reaction_target_id ~target_type target_id =
  match target_type with
  | Reaction_post -> Result.map Post_id.to_string (Post_id.of_string target_id)
  | Reaction_comment -> Result.map Comment_id.to_string (Comment_id.of_string target_id)
;;

let canonical_reaction_targets targets =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (target_type, target_id) :: rest ->
      let* target_id = canonical_reaction_target_id ~target_type target_id in
      loop ((target_type, target_id) :: acc) rest
  in
  loop [] targets
;;

let ensure_reaction_target_unlocked store ~target_type ~target_id =
  match target_type with
  | Reaction_post ->
    (match Post_id.of_string target_id with
     | Error e -> Error e
     | Ok pid ->
       if Hashtbl.mem store.posts (Post_id.to_string pid)
       then Ok ()
       else Error (Post_not_found target_id))
  | Reaction_comment ->
    (match Comment_id.of_string target_id with
     | Error e -> Error e
     | Ok cid ->
       if Hashtbl.mem store.comments (Comment_id.to_string cid)
       then Ok ()
       else Error (Comment_not_found target_id))
;;

module Reaction_emoji_map = Map.Make (String)
module Reaction_emoji_set = Set.Make (String)

let compare_reaction_target_type a b =
  match a, b with
  | Reaction_post, Reaction_post | Reaction_comment, Reaction_comment -> 0
  | Reaction_post, Reaction_comment -> -1
  | Reaction_comment, Reaction_post -> 1
;;

let equal_reaction_target_type a b = compare_reaction_target_type a b = 0

module Reaction_target_map = Map.Make (struct
    type t = reaction_target_type * string

    let compare (lt, lid) (rt, rid) =
      let c = compare_reaction_target_type lt rt in
      if c <> 0 then c else String.compare lid rid
  end)

type reaction_summary_bucket =
  { counts : int Reaction_emoji_map.t
  ; reacted : Reaction_emoji_set.t
  ; recent_users : (string * float) list Reaction_emoji_map.t
  }

let empty_reaction_summary_bucket =
  { counts = Reaction_emoji_map.empty
  ; reacted = Reaction_emoji_set.empty
  ; recent_users = Reaction_emoji_map.empty
  }
;;

let add_reaction_to_summary_bucket bucket ?user_id (reaction : reaction) =
  let reaction_user_id = Agent_id.to_string reaction.user_id in
  let current =
    Reaction_emoji_map.find_opt reaction.emoji bucket.counts
    |> Option.value ~default:0
  in
  let counts =
    Reaction_emoji_map.add reaction.emoji (current + 1) bucket.counts
  in
  let users =
    Reaction_emoji_map.find_opt reaction.emoji bucket.recent_users
    |> Option.value ~default:[]
  in
  let recent_users =
    Reaction_emoji_map.add
      reaction.emoji
      ((reaction_user_id, reaction.created_at) :: users)
      bucket.recent_users
  in
  let reacted =
    match user_id with
    | Some user when String.equal reaction_user_id user ->
      Reaction_emoji_set.add reaction.emoji bucket.reacted
    | Some _ | None -> bucket.reacted
  in
  { counts; reacted; recent_users }
;;

let reaction_summaries_of_bucket bucket =
  List.filter_map
    (fun emoji ->
       let count =
         Reaction_emoji_map.find_opt emoji bucket.counts
         |> Option.value ~default:0
       in
       if count = 0
       then None
       else
         Some
           { emoji
           ; count
           ; reacted = Reaction_emoji_set.mem emoji bucket.reacted
           ; recent_user_ids =
               Reaction_emoji_map.find_opt emoji bucket.recent_users
               |> Option.value ~default:[]
               |> List.sort (fun (_, a_ts) (_, b_ts) -> Stdlib.Float.compare b_ts a_ts)
               |> List.map fst
               |> List.filteri (fun idx _ -> idx < 5)
           })
    board_reaction_emojis
;;

let reaction_summaries_unlocked store ~target_type ~target_id ?user_id () =
  let bucket =
    Hashtbl.fold
      (fun _ (reaction : reaction) acc ->
         if equal_reaction_target_type reaction.target_type target_type
            && String.equal reaction.target_id target_id
         then add_reaction_to_summary_bucket acc ?user_id reaction
         else acc)
      store.reactions
      empty_reaction_summary_bucket
  in
  reaction_summaries_of_bucket bucket
;;

let reaction_summaries_batch_unlocked store ~targets ?user_id () =
  let target_buckets =
    List.fold_left
      (fun acc target ->
         Reaction_target_map.add target empty_reaction_summary_bucket acc)
      Reaction_target_map.empty
      targets
  in
  let target_buckets =
    Hashtbl.fold
      (fun _ (reaction : reaction) acc ->
         let key = reaction.target_type, reaction.target_id in
         match Reaction_target_map.find_opt key acc with
         | None -> acc
         | Some bucket ->
           Reaction_target_map.add
             key
             (add_reaction_to_summary_bucket bucket ?user_id reaction)
             acc)
      store.reactions
      target_buckets
  in
  Reaction_target_map.fold
    (fun target bucket acc -> (target, reaction_summaries_of_bucket bucket) :: acc)
    target_buckets
    []
;;

let normalize_reaction_user_id = function
  | Some user when not (String.equal (String.trim user) "") -> Some (String.trim user)
  | Some _ | None -> None
;;

let list_reactions store ~target_type ~target_id ?user_id () =
  maybe_sweep store;
  let user_id = normalize_reaction_user_id user_id in
  with_persist_lock store (fun () ->
    let* () = Board_reactions_source.require_readable store in
    let* target_id = canonical_reaction_target_id ~target_type target_id in
    with_lock store (fun () ->
      match ensure_reaction_target_unlocked store ~target_type ~target_id with
      | Error e -> Error e
      | Ok () -> Ok (reaction_summaries_unlocked store ~target_type ~target_id ?user_id ())))
;;

let list_reactions_batch store ~targets ?user_id () =
  maybe_sweep store;
  let user_id = normalize_reaction_user_id user_id in
  with_persist_lock store (fun () ->
    let* () = Board_reactions_source.require_readable store in
    let* targets = canonical_reaction_targets targets in
    with_lock store (fun () ->
      Ok (reaction_summaries_batch_unlocked store ~targets ?user_id ())))
;;

type staged_reaction_toggle =
  { key : string
  ; previous : reaction option
  ; desired : reaction option
  ; snapshot : string
  ; outcome : reaction_toggle_result
  }

let set_reaction_unlocked store key = function
  | None -> Hashtbl.remove store.reactions key
  | Some reaction -> Hashtbl.replace store.reactions key reaction
;;

let same_reaction_state (left : reaction option) (right : reaction option) =
  match left, right with
  | None, None -> true
  | Some left, Some right ->
    equal_reaction_target_type left.target_type right.target_type
    && String.equal left.target_id right.target_id
    && String.equal (Agent_id.to_string left.user_id) (Agent_id.to_string right.user_id)
    && String.equal left.emoji right.emoji
    && Float.equal left.created_at right.created_at
  | None, Some _ | Some _, None -> false
;;

let stage_reaction_toggle_unlocked store ~target_type ~target_id ~user_id ~emoji =
  match ensure_reaction_target_unlocked store ~target_type ~target_id with
  | Error _ as error -> error
  | Ok () ->
    let user_id_string = Agent_id.to_string user_id in
    let key = reaction_key ~target_type ~target_id ~user_id:user_id_string ~emoji in
    let previous = Hashtbl.find_opt store.reactions key in
    let desired =
      match previous with
      | Some _ -> None
      | None ->
        Some
          { target_type
          ; target_id
          ; user_id
          ; emoji
          ; created_at = Time_compat.now ()
          }
    in
    set_reaction_unlocked store key desired;
    Fun.protect
      ~finally:(fun () -> set_reaction_unlocked store key previous)
      (fun () ->
        let reacted = Option.is_some desired in
        let summary =
          reaction_summaries_unlocked
            store
            ~target_type
            ~target_id
            ~user_id:user_id_string
            ()
        in
        let snapshot = reactions_jsonl_unlocked store in
        Ok
          { key
          ; previous
          ; desired
          ; snapshot
          ; outcome =
              { target_type
              ; target_id
              ; user_id = user_id_string
              ; emoji
              ; reacted
              ; summary
              }
          })
;;

let commit_staged_reaction_unlocked store staged =
  let outcome = staged.outcome in
  match
    ensure_reaction_target_unlocked
      store
      ~target_type:outcome.target_type
      ~target_id:outcome.target_id
  with
  | Error _ as error -> error
  | Ok () ->
    let current = Hashtbl.find_opt store.reactions staged.key in
    if not (same_reaction_state current staged.previous)
    then
      (* The caller's request was valid, but the model changed after the file
         write. The source retains that known receipt without acknowledging it
         or rolling it back. Report the storage/model conflict as [Io_error]. *)
      Error
        (Io_error
           (Printf.sprintf
              "reaction state changed before durable commit: target=%s user=%s emoji=%s"
              outcome.target_id
              outcome.user_id
              outcome.emoji))
    else (
      set_reaction_unlocked store staged.key staged.desired;
      Ok outcome)
;;

let toggle_reaction store ~target_type ~target_id ~user_id ~emoji
  : (reaction_toggle_result, board_error) Result.t
  =
  let* target_id = canonical_reaction_target_id ~target_type target_id in
  maybe_sweep store;
  match Agent_id.of_string user_id, normalize_reaction_emoji emoji with
  | Error e, _ -> Error e
  | _, Error e -> Error e
  | Ok user_id, Ok emoji ->
    with_persist_lock store (fun () ->
      let module Source = Board_reactions_source in
      let* () = Source.require_readable store in
      let* () = require_posts_source_readable store in
      let* staged = with_lock store (fun () ->
        stage_reaction_toggle_unlocked store ~target_type ~target_id ~user_id ~emoji) in
      let outcome = Source.rewrite store staged.snapshot in
      let result = match outcome with
        | Source.Written { publication; _ } ->
          let projected =
            try with_lock store (fun () -> commit_staged_reaction_unlocked store staged)
            with exception_ ->
              Source.fail_publication store publication exception_ (Printexc.get_raw_backtrace ()) in
          (match projected with
           | Ok value ->
             let* () = Source.acknowledge_publication store publication in
             Ok value
           | Error error -> Source.reject_publication store publication error; Error error)
        | Source.Not_written _ | Source.Unknown _ -> Error (Io_error "Board data is unavailable.") in
      let result = Source.finish_write outcome result in
      try
        (match result with
         | Ok _ -> ()
         | Error error -> record_persist_error ~where:"reactions source" (show_board_error error));
        result
      with exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        Board_posts_source.defer_reserved ~result:(Result.map (fun _ -> ()) result)
          exception_ backtrace;
        Printexc.raise_with_backtrace exception_ backtrace)
;;
