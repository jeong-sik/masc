(** See [keeper_world_observation_message_scope.mli] for the contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_memory
open Keeper_context_runtime

let message_feed_targets (meta : keeper_meta) =
  if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]
;;

(* Identities are minted once at the parse boundary by
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

(* The direct-line role is a closed sum, not a string label.
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
        (match m.audio with
         | Some _ -> None
         | None -> Some { role = Assistant; speaker_label = None; content })
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
      | Keeper_chat_store.Role.System | Keeper_chat_store.Role.Request_failure -> None)
  |> List_util.take_last limit
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
    (* The header prose is the [world.transcript.*] slots of config/prompts/keeper.md; a
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

(* The scope lane: an unmentioned line addressed to this Keeper that it owes
   an answer. The operator's lines are. A direct Keeper-to-Keeper message
   ([Surface_ref.Agent], written for masc_keeper_msg / delegate) is too: it
   was sent to this Keeper, and the watermarked lane is what re-raises it if
   its turn never answered. Another Keeper's broadcast is standing context
   for the fleet layer, and connector chatter is ignored. *)
let is_scope_line (m : Keeper_chat_store.chat_message) : bool =
  match m.speaker with
  | Some (s : Keeper_chat_store.speaker) ->
    (match s.speaker_authority with
     | Keeper_chat_store.Owner -> true
     | Keeper_chat_store.External -> false
     | Keeper_chat_store.Keeper ->
       (match m.surface with
        | Some Surface_ref.Agent -> true
        | Some
            ( Surface_ref.Broadcast
            | Surface_ref.Dashboard _
            | Surface_ref.Discord _
            | Surface_ref.Slack _
            | Surface_ref.Webhook _
            | Surface_ref.Gate _ )
        | None -> false))
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
  else if is_scope_line m
  then Some Scope
  else None
;;

let pending_messages_of_index
      ?ack_id
      ~(targets : string list)
      (index : Keeper_chat_observation_index.t)
  : pending_message list
  =
  let target_ids = Keeper_lane_mentions.target_ids_of targets in
  Keeper_chat_observation_index.pending_users ?ack_id index
  |> List.filter_map (fun (m : Keeper_chat_store.chat_message) ->
    lane_of ~target_ids m
    |> Option.map (fun kind ->
      { message_id = m.id
      ; speaker = speaker_display m
      ; content = m.content
      ; kind
      }))
;;

let pending_messages_of_messages ?ack_id ~targets messages =
  pending_messages_of_index ?ack_id ~targets
    (Keeper_chat_observation_index.of_messages messages)
;;

let fleet_messages_of_index ~limit ~targets index =
  let target_ids = Keeper_lane_mentions.target_ids_of targets in
  let rec take remaining acc = function
    | [] -> acc
    | _ when remaining <= 0 -> acc
    | (message : Keeper_chat_store.chat_message) :: rest ->
      (match lane_of ~target_ids message with
       | Some (Mention | Scope) -> take remaining acc rest
       | None ->
         take (remaining - 1)
           ({ fleet_speaker = speaker_display message; fleet_content = message.content } :: acc)
           rest)
  in
  (* Candidates are newest first; prepending selected rows restores append order.
     The current targets are applied before the limit, independent of ack. *)
  take limit [] (Keeper_chat_observation_index.fleet_candidates_rev index)
;;

let fleet_messages_of_messages ~limit ~targets messages =
  fleet_messages_of_index ~limit ~targets (Keeper_chat_observation_index.of_messages messages)
;;

let collect_message_scope_and_fleet
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(fleet_limit : int)
  : pending_message list * fleet_message list
  =
  let index =
    Keeper_chat_store.load_observation ~base_dir:config.base_path ~keeper_name:meta.name
  in
  let targets = message_feed_targets meta in
  let pending =
    pending_messages_of_index
      ?ack_id:meta.runtime.message_scope_ack_id
      ~targets
      index
  in
  let fleet = fleet_messages_of_index ~limit:fleet_limit ~targets index in
  pending, fleet
;;
