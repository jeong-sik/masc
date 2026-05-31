(** See [keeper_world_observation_message_scope.mli] for the contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_memory
open Keeper_context_runtime

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

(* Message feed cursor for direct @mention detection.  The feed advances through
   [Coord.get_all_messages_raw ~since_seq] using
   [meta.runtime.last_seen_message_seq], so each keeper scans each message once
   across heartbeats. *)
let collect_message_scope ~(config : Coord.config) ~(meta : keeper_meta)
  : (string * string) list * (string * string) list * (string * int) list
  =
  let targets = message_feed_targets meta in
  let self_tokens = self_identity_tokens meta in
  let batch_limit = Keeper_config.keeper_batch_limit () in
  let since_seq = meta.runtime.last_seen_message_seq in
  let rec consume remaining last_processed mentions = function
    | [] -> last_processed, List.rev mentions
    | (msg : Masc_domain.message) :: rest ->
      let author = String.trim msg.from_agent in
      if author = "" || is_self_author ~self_tokens author
      then consume remaining msg.seq mentions rest
      else if
        Coord_task_cache_invariant.stale_active_task_signal_present
          ~config
          ~from_agent:author
          ~module_name:"keeper_world_observation"
          ~content:msg.content
      then consume remaining msg.seq mentions rest
      else if exact_direct_mention_present ~targets msg.content
      then
        (* Saturation: stop without advancing past this mention so it is
           re-surfaced next cycle (mirrors the former [`Saturated] path). *)
        if remaining <= 0
        then last_processed, List.rev mentions
        else
          consume
            (remaining - 1)
            msg.seq
            ((msg.from_agent, msg.content) :: mentions)
            rest
      else consume remaining msg.seq mentions rest
  in
  let messages =
    try Coord.get_all_messages_raw config ~since_seq with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> []
  in
  let last_processed, mentions = consume batch_limit since_seq [] messages in
  let cursor_updates =
    if last_processed > since_seq then [ meta.name, last_processed ] else []
  in
  mentions, [], cursor_updates
;;

(* The cursor-update list is room-less now (at most one entry); fold the highest
   seq into the single global cursor. *)
let apply_message_cursor_updates (meta : keeper_meta) (updates : (string * int) list)
  : keeper_meta
  =
  let max_seq =
    List.fold_left
      (fun acc (_key, seq) -> if seq > acc then seq else acc)
      meta.runtime.last_seen_message_seq
      updates
  in
  { meta with runtime = { meta.runtime with last_seen_message_seq = max_seq } }
;;
