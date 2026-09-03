(** See [keeper_world_observation_message_scope.mli] for the contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_memory
open Keeper_context_runtime

let message_feed_targets (meta : keeper_meta) =
  if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]
;;

(* RFC-0232 §3.4: identities are minted once at the parse boundary by
   [Keeper_id.of_string]; the multi-form token-set expansion that used to
   live here moved inside it.  A keeper's self is the (≤2-element) id set
   minted from its name and agent name — they usually collapse to the
   same canonical id. *)
let self_ids (meta : keeper_meta) : Keeper_identity.Keeper_id.t list =
  List.filter_map
    Keeper_identity.Keeper_id.of_string
    [ meta.name ]
  |> List.sort_uniq Keeper_identity.Keeper_id.compare
;;

(* Single source of truth for "is this author one of us?". *)
let is_self_author ~self_ids (author : string) : bool =
  match Keeper_identity.Keeper_id.of_string author with
  | None -> false
  | Some author_id ->
    List.exists (Keeper_identity.Keeper_id.equal author_id) self_ids
;;

type pending_kind =
  | Mention
  | Scope

type pending_message =
  { message_id : string
  ; speaker : string
  ; content : string
  ; kind : pending_kind
  }

(* A keeper broadcast projected into this keeper's transcript. Carries no
   message id: the layer has no watermark, so nothing keys off row identity. *)
type fleet_message =
  { fleet_speaker : string
  ; fleet_content : string
  }

let kind_equal left right =
  match left, right with
  | Mention, Mention | Scope, Scope -> true
  | Mention, Scope | Scope, Mention -> false
;;

let pairs_of_kind kind messages =
  messages
  |> List.filter_map (fun message ->
    if kind_equal kind message.kind
    then Some (message.speaker, message.content)
    else None)
;;

let has_kind kind messages =
  List.exists (fun message -> kind_equal kind message.kind) messages
;;

(* RFC-0232 P1: the direct-line role is a closed sum, not a string label.
   The projection has exactly three shapes (a tool row is shown as its call
   name); [to_label] is the single place the display vocabulary lives, so the
   renderer never re-derives semantics from a free string. *)
type direct_line_role =
  | User
  | Assistant
  | Tool_call

let direct_line_role_to_label = function
  | User -> "user"
  | Assistant -> "assistant"
  | Tool_call -> "tool_call"

type recent_direct_line = {
  role : direct_line_role;
  speaker_label : string option;
  content : string;
}

let speaker_display (m : Keeper_chat_store.chat_message) : string =
  let from_speaker =
    match m.speaker with
    | Some (s : Keeper_chat_store.speaker) -> s.speaker_name
    | None -> None
  in
  match from_speaker with
  | Some name when String.trim name <> "" -> name
  | _ ->
    (match m.surface with
     | Some surface when String.trim (Surface_ref.lane_label surface) <> "" ->
         Surface_ref.lane_label surface
     | _ -> "someone")
;;

let default_recent_direct_limit = 8
let recent_direct_content_max_len = 600

let collapse_line_breaks text =
  text
  |> Inference_utils.sanitize_text_utf8
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")
  |> String.concat " "
  |> short_preview ~max_len:recent_direct_content_max_len
;;

let take_last limit items =
  let limit = max 0 limit in
  let len = List.length items in
  let rec drop n xs =
    if n <= 0 then xs
    else
      match xs with
      | [] -> []
      | _ :: rest -> drop (n - 1) rest
  in
  drop (max 0 (len - limit)) items
;;

let recent_direct_conversation_of_messages
      ?(limit = default_recent_direct_limit)
      (messages : Keeper_chat_store.chat_message list)
  : recent_direct_line list
  =
  messages
  |> List.filter_map (fun (m : Keeper_chat_store.chat_message) ->
    let content = collapse_line_breaks m.content in
    if content = "" then None
    else
      match m.role with
      | Keeper_chat_store.Role.User ->
        Some
          { role = User
          ; speaker_label = Some (speaker_display m)
          ; content
          }
      | Keeper_chat_store.Role.Assistant ->
        (match m.kind with
         | Keeper_chat_store.Row_kind.Transport_failure -> None
         | Keeper_chat_store.Row_kind.Utterance ->
           (match m.audio with
            | Some _ -> None
            | None ->
              Some
                { role = Assistant
                ; speaker_label = None
                ; content
                }))
      | Keeper_chat_store.Role.Tool ->
        (match m.tool_call_name with
         | None -> None
         | Some name ->
           let name = collapse_line_breaks name in
           if name = "" then None
           else
             Some
               { role = Tool_call
               ; speaker_label = None
               ; content = name
               })
      | Keeper_chat_store.Role.System -> None)
  |> take_last limit
;;

let collect_recent_direct_conversation
      ?limit
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ()
  : recent_direct_line list
  =
  Keeper_chat_store.load ~base_dir:config.base_path ~keeper_name:meta.name
  |> recent_direct_conversation_of_messages ?limit
;;

let render_recent_direct_conversation_context
      (lines : recent_direct_line list)
  : string
  =
  match lines with
  | [] -> ""
  | _ ->
    let render_line line =
      let speaker =
        match line.speaker_label with
        | None -> ""
        | Some value -> Printf.sprintf "/%s" value
      in
      Printf.sprintf "- %s%s: %s"
        (direct_line_role_to_label line.role) speaker line.content
    in
    (* The header prose lives in config/prompts/keeper.world.transcript.md; a
       slot that does not render is logged and the block degrades to the bare
       rows — the transcript is the data, the framing is the template's
       (#32848 fallback contract). *)
    let header_lines =
      let render key =
        match Prompt_registry.render_prompt_template key [] with
        | Ok text -> Some text
        | Error detail ->
          Log.Misc.error
            "keeper world transcript prompt %s did not render, falling back to the bare \
             transcript rows: %s"
            key
            detail;
          None
      in
      match
        ( render Prompt_names.keeper_world_transcript_header
        , render Prompt_names.keeper_world_transcript_intro )
      with
      | Some header, Some intro -> [ header; intro ]
      | _ -> []
    in
    String.concat "\n" (header_lines @ List.map render_line lines)
;;

module StringSet = Set_util.StringSet

let acknowledged_turn_refs messages =
  List.fold_left
    (fun refs (message : Keeper_chat_store.chat_message) ->
      match message.role, message.kind, message.turn_ref with
      | Keeper_chat_store.Role.Assistant,
        Keeper_chat_store.Row_kind.Utterance,
        Some turn_ref ->
        StringSet.add (Ids.Turn_ref.to_string turn_ref) refs
      | Keeper_chat_store.Role.Assistant,
        Keeper_chat_store.Row_kind.Transport_failure,
        _
      | Keeper_chat_store.Role.Assistant,
        Keeper_chat_store.Row_kind.Utterance,
        None
      | Keeper_chat_store.Role.User, _, _
      | Keeper_chat_store.Role.System, _, _
      | Keeper_chat_store.Role.Tool, _, _ -> refs)
    StringSet.empty
    messages
;;

let answered_delivery_keys messages =
  List.filter_map
    (fun (message : Keeper_chat_store.chat_message) ->
      match message.role, message.kind, message.delivery_provenance with
      | Keeper_chat_store.Role.Assistant,
        Keeper_chat_store.Row_kind.Utterance,
        Some provenance ->
        Some provenance.Keeper_chat_delivery_identity.delivery_key
      | Keeper_chat_store.Role.Assistant,
        Keeper_chat_store.Row_kind.Transport_failure,
        _
      | Keeper_chat_store.Role.Assistant,
        Keeper_chat_store.Row_kind.Utterance,
        None
      | Keeper_chat_store.Role.User, _, _
      | Keeper_chat_store.Role.System, _, _
      | Keeper_chat_store.Role.Tool, _, _ ->
        None)
    messages
;;

let exact_delivery_was_answered answered = function
  | None -> false
  | Some provenance ->
    List.exists
      (Keeper_chat_delivery_identity.delivery_key_equal
         provenance.Keeper_chat_delivery_identity.delivery_key)
      answered
;;

let messages_after_ack ~ack_id messages =
  match ack_id with
  | None -> messages
  | Some acknowledged_id ->
    let rec drop = function
      | [] -> None
      | (message : Keeper_chat_store.chat_message) :: rest ->
        if String.equal message.id acknowledged_id then Some rest else drop rest
    in
    Option.value ~default:messages (drop messages)
;;

let pending_user_lines ?ack_id (messages : Keeper_chat_store.chat_message list) =
  let acknowledged = acknowledged_turn_refs messages in
  let answered_deliveries = answered_delivery_keys messages in
  messages_after_ack ~ack_id messages
  |> List.filter (fun (message : Keeper_chat_store.chat_message) ->
    match message.role, message.turn_ref with
    | Keeper_chat_store.Role.User, Some turn_ref ->
      not (StringSet.mem (Ids.Turn_ref.to_string turn_ref) acknowledged)
      && not
           (exact_delivery_was_answered
              answered_deliveries
              message.delivery_provenance)
    | Keeper_chat_store.Role.User, None ->
      not
        (exact_delivery_was_answered
           answered_deliveries
           message.delivery_provenance)
    | Keeper_chat_store.Role.Assistant, _
    | Keeper_chat_store.Role.System, _
    | Keeper_chat_store.Role.Tool, _ -> false)
;;

let is_owner_authored (m : Keeper_chat_store.chat_message) : bool =
  match m.speaker with
  | Some (s : Keeper_chat_store.speaker) -> s.speaker_authority = Keeper_chat_store.Owner
  | None -> false
;;

(* Which reactive lane a row belongs to, or [None] when it is addressed to
   nobody here. Both the reactive lanes and the fleet layer read this one
   function — the lanes on [Some], the fleet layer on [None] — so a row cannot
   reach both. Splitting the classification would leave disjointness as a
   property of two expressions staying complements, which nothing checks. *)
let lane_of ~target_ids (m : Keeper_chat_store.chat_message) : pending_kind option =
  if Keeper_lane_mentions.ids_match ~target_ids m.mentions
  then Some Mention
  else if is_owner_authored m
  then Some Scope
  else None
;;

let pending_messages_of_messages
      ?ack_id
      ~(targets : string list)
      (messages : Keeper_chat_store.chat_message list)
  : pending_message list
  =
  let target_ids = Keeper_lane_mentions.target_ids_of targets in
  pending_user_lines ?ack_id messages
  |> List.filter_map (fun (m : Keeper_chat_store.chat_message) ->
    lane_of ~target_ids m
    |> Option.map (fun kind ->
      { message_id = m.id
      ; speaker = speaker_display m
      ; content = m.content
      ; kind
      }))
;;

(* RFC-0230 P2 — scope messages: a keeper's lane is, in practice, an operator
   (Owner) conversation. The operator often addresses the keeper without an
   "@name", so an unanswered Owner line that is not already a mention is a scope
   message. External (connector) chatter without a mention is ignored, so a busy
   channel does not flood the keeper. Same watermark as mentions; the mention
   exclusion keeps the two reactive signals disjoint. *)
let pending_scope_of_messages
      ?ack_id
      ~(targets : string list)
      (messages : Keeper_chat_store.chat_message list)
  : (string * string) list
  =
  pending_messages_of_messages ?ack_id ~targets messages
  |> pairs_of_kind Scope
;;

let pending_mentions_of_messages
      ?ack_id
      ~(targets : string list)
      (messages : Keeper_chat_store.chat_message list)
  : (string * string) list
  =
  pending_messages_of_messages ?ack_id ~targets messages
  |> pairs_of_kind Mention
;;

(* Fleet messages: keeper broadcasts projected into this keeper's transcript.
   [Surface_ref.Broadcast] is the typed marker the fleet fanout writes; an
   [Surface_ref.Agent] row (direct keeper-to-keeper delivery) that lands in no
   reactive lane is the same standing context, so the filter reads the two
   variants rather than inspecting content.

   Unlike the two reactive lanes this layer carries no watermark. A projected
   broadcast is context, not an outstanding obligation, and the lane
   acknowledgement only advances on autonomous turns — a keeper with
   [proactive_enabled = false] would accumulate rows forever. Newest [limit]
   rows, rendered in arrival order. *)
let fleet_messages_of_messages
      ~(limit : int)
      ~(targets : string list)
      (messages : Keeper_chat_store.chat_message list)
  : fleet_message list
  =
  if limit <= 0
  then []
  else (
    let target_ids = Keeper_lane_mentions.target_ids_of targets in
    messages
    |> List.filter (fun (m : Keeper_chat_store.chat_message) ->
      match m.role, m.surface with
      | Keeper_chat_store.Role.User, Some (Surface_ref.Agent | Surface_ref.Broadcast)
        -> Option.is_none (lane_of ~target_ids m)
      | ( Keeper_chat_store.Role.User
        , Some
            ( Surface_ref.Dashboard _
            | Surface_ref.Discord _
            | Surface_ref.Slack _
            | Surface_ref.Webhook _
            | Surface_ref.Gate _ ) )
      | Keeper_chat_store.Role.User, None
      | Keeper_chat_store.Role.Assistant, _
      | Keeper_chat_store.Role.System, _
      | Keeper_chat_store.Role.Tool, _ -> false)
    |> List.rev
    |> List.take limit
    |> List.rev
    |> List.map (fun (m : Keeper_chat_store.chat_message) ->
      { fleet_speaker = speaker_display m; fleet_content = m.content }))
;;

(* Both layers read the same transcript, which reaches 1.8 MB in production.
   Loading once and deriving both keeps the per-turn read count at one and
   makes the disjointness visible: the same rows feed both filters. *)
let collect_message_scope_and_fleet
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(fleet_limit : int)
  : pending_message list * fleet_message list
  =
  let messages =
    Keeper_chat_store.load_all ~base_dir:config.base_path ~keeper_name:meta.name
  in
  let targets = message_feed_targets meta in
  let pending =
    pending_messages_of_messages
      ?ack_id:meta.runtime.message_scope_ack_id
      ~targets
      messages
  in
  let fleet = fleet_messages_of_messages ~limit:fleet_limit ~targets messages in
  pending, fleet
;;
