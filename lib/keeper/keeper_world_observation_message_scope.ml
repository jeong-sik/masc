(** See [keeper_world_observation_message_scope.mli] for the contract. *)

open Keeper_types
open Keeper_memory
open Keeper_exec_context

let scope_message_feed_enabled (meta : keeper_meta) : bool =
  meta.room_signal_prompt_enabled
;;

let message_feed_targets (meta : keeper_meta) =
  if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]
;;

let normalized_identity_token value =
  let trimmed = String.lowercase_ascii (String.trim value) in
  if trimmed = "" then None else Some trimmed
;;

let identity_tokens_of_value value =
  let trimmed = String.trim value in
  [ normalized_identity_token trimmed
  ; Option.bind
      (Keeper_identity.canonical_keeper_name_from_agent_name trimmed)
      normalized_identity_token
  ; Option.bind (Keeper_identity.canonical_keeper_name trimmed) normalized_identity_token
  ]
  |> List.filter_map (fun value -> value)
  |> List.sort_uniq String.compare
;;

let self_identity_tokens (meta : keeper_meta) =
  [ meta.name; meta.agent_name ]
  |> List.map identity_tokens_of_value
  |> List.flatten
  |> List.sort_uniq String.compare
;;

(* Single source of truth for "is this author one of us?". *)
let is_self_author ~self_tokens (author : string) : bool =
  identity_tokens_of_value author
  |> List.exists (fun author_token -> List.mem author_token self_tokens)
;;

let is_keeper_authored_message author =
  Option.is_some (Keeper_identity.canonical_keeper_name_from_agent_name author)
;;

let collect_message_scope ~(config : Coord.config) ~(meta : keeper_meta)
  : (string * string) list * (string * string) list * (string * int) list
  =
  let targets = message_feed_targets meta in
  let broad_scope = scope_message_feed_enabled meta in
  let self_tokens = self_identity_tokens meta in
  let batch_limit = Keeper_config.keeper_batch_limit () in
  let rec consume_room_messages remaining last_processed mentions scope_messages
    = function
    | [] -> `Done, remaining, last_processed, List.rev mentions, List.rev scope_messages
    | (msg : Masc_domain.message) :: rest ->
      let author = String.trim msg.from_agent in
      if author = "" || is_self_author ~self_tokens author
      then consume_room_messages remaining msg.seq mentions scope_messages rest
      else if
        Coord_task_cache_invariant.stale_active_task_signal_present
          ~config
          ~from_agent:author
          ~module_name:"keeper_world_observation"
          ~content:msg.content
      then consume_room_messages remaining msg.seq mentions scope_messages rest
      else if exact_direct_mention_present ~targets msg.content
      then
        if remaining <= 0
        then
          ( `Saturated
          , remaining
          , last_processed
          , List.rev mentions
          , List.rev scope_messages )
        else
          consume_room_messages
            (remaining - 1)
            msg.seq
            ((msg.from_agent, msg.content) :: mentions)
            scope_messages
            rest
      else if broad_scope
      then
        (* Broad room scope is for operator/human context; direct mentions
           above still allow explicit keeper-to-keeper handoff. *)
        if is_keeper_authored_message author
        then consume_room_messages remaining msg.seq mentions scope_messages rest
        else if remaining <= 0
        then
          ( `Saturated
          , remaining
          , last_processed
          , List.rev mentions
          , List.rev scope_messages )
        else
          consume_room_messages
            (remaining - 1)
            msg.seq
            mentions
            ((msg.from_agent, msg.content) :: scope_messages)
            rest
      else consume_room_messages remaining msg.seq mentions scope_messages rest
  in
  let rec consume_rooms remaining mentions_acc scope_acc cursor_acc = function
    | [] -> mentions_acc, scope_acc, List.rev cursor_acc
    | _ when remaining <= 0 -> mentions_acc, scope_acc, List.rev cursor_acc
    | room_id :: rest ->
      let since_seq = room_cursor_for meta room_id in
      let messages =
        try Coord.get_all_messages_raw config ~since_seq with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | _ -> []
      in
      let status, remaining, last_processed, room_mentions, scoped_messages =
        consume_room_messages remaining since_seq [] [] messages
      in
      let cursor_acc =
        if last_processed > since_seq
        then (room_id, last_processed) :: cursor_acc
        else cursor_acc
      in
      let mentions_acc = mentions_acc @ room_mentions in
      let scope_acc = scope_acc @ scoped_messages in
      (match status with
       | `Done -> consume_rooms remaining mentions_acc scope_acc cursor_acc rest
       | `Saturated -> mentions_acc, scope_acc, List.rev cursor_acc)
  in
  consume_rooms batch_limit [] [] [] meta.joined_room_ids
;;

let apply_message_cursor_updates (meta : keeper_meta) (updates : (string * int) list)
  : keeper_meta
  =
  List.fold_left (fun acc (room_id, seq) -> set_room_cursor acc room_id seq) meta updates
;;
