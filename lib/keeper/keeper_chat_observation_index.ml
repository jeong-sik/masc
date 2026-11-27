open Keeper_chat_types

module String_map = Map.Make (String)
module String_set = Set.Make (String)
module Position_map = Map.Make (Int)
module Delivery_set = Set.Make (struct
  type t = Keeper_chat_delivery_identity.delivery_key
  let compare = Keeper_chat_delivery_identity.delivery_key_compare
end)

type t =
  { next_position : int
  ; messages_rev : chat_message list
  ; first_positions : int String_map.t
  ; users : chat_message Position_map.t
  ; answered_turns : String_set.t
  ; answered_deliveries : Delivery_set.t
  ; fleet_rev : chat_message list
  }

let empty =
  { next_position = 0; messages_rev = []; first_positions = String_map.empty
  ; users = Position_map.empty; answered_turns = String_set.empty
  ; answered_deliveries = Delivery_set.empty; fleet_rev = [] }
;;

(* An utterance answers a delivery only when it actually spoke. Checkpoint and
   defer boundaries persist an empty-content assistant row as the carrier for
   the typed status block, and a reasoning-only reply leaves no text either;
   counting those rows as answers dropped the user message they followed
   without it ever reaching a turn (2026-09-10 drain investigation). An audio
   reply speaks without text, and a media-only reply (empty content carrying
   Image/Attach/Voice blocks) is a delivered answer — the stream handler
   completes those as Delivered, so excluding them would park their delivery
   pending forever. [Status] blocks are the carrier itself, and [Thinking] /
   [Trace] blocks are observability, not user-facing answer content. *)
let block_is_answer_content = function
  | Keeper_chat_blocks.Status _ | Keeper_chat_blocks.Thinking _ | Keeper_chat_blocks.Trace _ ->
    false
  | Keeper_chat_blocks.Text _ | Keeper_chat_blocks.Heading _
  | Keeper_chat_blocks.Unordered_list _ | Keeper_chat_blocks.Callout _
  | Keeper_chat_blocks.Table _ | Keeper_chat_blocks.Code _
  | Keeper_chat_blocks.Mermaid _ | Keeper_chat_blocks.Chart _ | Keeper_chat_blocks.Svg _
  | Keeper_chat_blocks.Voice _ | Keeper_chat_blocks.Attach _
  | Keeper_chat_blocks.Image _ | Keeper_chat_blocks.Link _
  | Keeper_chat_blocks.Fusion _ ->
    true
;;

let utterance_spoke (message : chat_message) =
  String.trim message.content <> ""
  || Option.is_some message.audio
  || (match message.blocks with
      | Some blocks -> List.exists block_is_answer_content blocks
      | None -> false)
;;

let is_fleet_candidate (message : chat_message) =
  match message.surface with
  | Some (Surface_ref.Agent | Surface_ref.Broadcast) -> true
  | Some (Surface_ref.Dashboard _ | Surface_ref.Discord _ | Surface_ref.Slack _
         | Surface_ref.Webhook _ | Surface_ref.Gate _) | None -> false
;;

let add index (message : chat_message) =
  let position = index.next_position in
  let first_positions =
    if String_map.mem message.id index.first_positions then index.first_positions
    else String_map.add message.id position index.first_positions
  in
  let index =
    { index with next_position = position + 1
    ; messages_rev = message :: index.messages_rev; first_positions }
  in
  match message.role with
  | Role.User ->
    { index with users = Position_map.add position message index.users
    ; fleet_rev =
        if is_fleet_candidate message then message :: index.fleet_rev else index.fleet_rev }
  | Role.Assistant ->
    if not (utterance_spoke message) then index
    else
      { index with
        answered_turns =
          (match message.turn_ref with
           | None -> index.answered_turns
           | Some turn_ref -> String_set.add (Ids.Turn_ref.to_string turn_ref) index.answered_turns)
      ; answered_deliveries =
          (match message.delivery_provenance with
           | None -> index.answered_deliveries
           | Some provenance -> Delivery_set.add provenance.delivery_key index.answered_deliveries)
      }
  | Role.Tool | Role.System | Role.Request_failure -> index
;;

let append = List.fold_left add
let of_messages messages = append empty messages
let contains_message ~message_id index = String_map.mem message_id index.first_positions
let messages index = List.rev index.messages_rev
let fleet_candidates_rev index = index.fleet_rev

let pending_users ?ack_id index =
  let start =
    match Option.bind ack_id (fun id -> String_map.find_opt id index.first_positions) with
    | None -> 0
    | Some position -> position + 1
  in
  Position_map.to_seq_from start index.users
  |> Seq.filter_map (fun (_, (message : chat_message)) ->
    let answered_turn =
      match message.turn_ref with
      | None -> false
      | Some turn_ref -> String_set.mem (Ids.Turn_ref.to_string turn_ref) index.answered_turns
    in
    let answered_delivery =
      match message.delivery_provenance with
      | None -> false
      | Some provenance -> Delivery_set.mem provenance.delivery_key index.answered_deliveries
    in
    if answered_turn || answered_delivery then None else Some message)
  |> List.of_seq
;;
