(** Pure persisted-field and HTTP projections of resolved chat data. *)

open Keeper_chat_types
open Keeper_approval_lifecycle

let speaker_fields = function
  | None -> []
  | Some sp ->
      Json_util.string_field_if_present "speaker_id" sp.speaker_id
      @ Json_util.string_field_if_present "speaker_name" sp.speaker_name
      @ [ ("speaker_authority", `String (authority_label sp.speaker_authority)) ]

(* RFC-0235 P1: nested ["audio"] assoc so the clip stays one unit on the
   JSONL row. Absent on rows written before voice transport; reads as
   [None] (the dashboard renders text-only, matching any non-voice turn).
   [expired] is written only when true so fresh clips stay byte-identical
   to rows written before this field existed; the history endpoint stamps
   it when the underlying MP3 has been reaped. *)
let audio_to_json a =
  let base =
    [ ("token", `String a.token)
    ; ("mime", `String a.mime)
    ; ("message_text", `String a.message_text)
    ]
  in
  let with_optional =
    base
    |> fun fs ->
    (match a.audio_url with
     | None -> fs
     | Some url -> fs @ [ ("audio_url", `String url) ])
    |> fun fs ->
    (match a.duration_sec with
     | None -> fs
     | Some d -> fs @ [ ("duration_sec", `Float d) ])
    |> fun fs ->
    (match a.device_id with
     | None -> fs
     | Some id -> fs @ [ ("device_id", `String id) ])
  in
  if a.expired then with_optional @ [ ("expired", `Bool true) ] else with_optional

let audio_fields = function
  | None -> []
  | Some a -> [ ("audio", `Assoc (audio_to_json a)) ]

let blocks_fields = function
  | None | Some [] -> []
  | Some blocks -> [ ("blocks", Keeper_chat_blocks.blocks_to_yojson blocks) ]
;;

let stream_lifecycle_fields = function
  | None | Some [] -> []
  | Some events ->
      [
        ( "stream_lifecycle",
          `List
            (List.map
               (fun event -> `String (stream_lifecycle_event_to_label event))
               events) );
      ]

let approval_lifecycle_to_json lifecycle =
  `Assoc
    ([ "approval_id", `String lifecycle.approval_id
     ; "phase", `String (approval_lifecycle_phase_to_label lifecycle.phase)
     ]
     @ Json_util.string_field_if_present "tool_name" lifecycle.tool_name
     @ Json_util.string_field_if_present "call_summary" lifecycle.call_summary
     @ (match lifecycle.artifact_ref with
        | None -> []
        | Some artifact_ref ->
          [ "artifact_ref", Tool_output.normalized_artifact_ref_to_json artifact_ref ]))
;;

let approval_lifecycle_fields = function
  | None -> []
  | Some lifecycle -> [ "approval_lifecycle", approval_lifecycle_to_json lifecycle ]
;;

let blocks_with_trace_block ~trace_block (m : chat_message) =
  let base =
    match m.blocks with
    | Some blocks -> blocks
    | None -> []
  in
  match m.role, trace_block with
  | (Role.Assistant | Role.Request_failure), Some trace_block -> base @ [ trace_block ]
  | (Role.User | Role.Assistant | Role.System | Role.Tool | Role.Request_failure), None
  | (Role.User | Role.System | Role.Tool), Some _ -> base

let blocks_fields_of_list = function
  | [] -> []
  | blocks -> [ ("blocks", Keeper_chat_blocks.blocks_to_yojson blocks) ]
;;

let rec last_opt = function
  | [] -> None
  | [ x ] -> Some x
  | _ :: rest -> last_opt rest

let stream_delivery_receipt_field value =
  [ ("delivery_receipt", `String value) ]

let chat_stream_contract_json ~trace_lookup_available ~trace_block
    (m : chat_message) =
  let field key value = (key, value) in
  let string_field key value = field key (`String value) in
  let base_fields =
    Json_util.string_field_if_present "turn_ref" (Option.map Ids.Turn_ref.to_string m.turn_ref)
  in
  match m.stream_lifecycle with
  | Some (_ :: _ as events) ->
      let labels = List.map stream_lifecycle_event_to_label events in
      `Assoc
        ([ string_field "source" "backend_stream_lifecycle"
         ; string_field "status" "backend_lifecycle_replay"
         ; string_field "reason"
             "history row records durable server stream lifecycle replay"
         ; field "lifecycle_events"
             (`List (List.map (fun label -> `String label) labels))
         ]
        @ stream_delivery_receipt_field "server_lifecycle_replay_only"
        @ Json_util.string_field_if_present "event_name" (last_opt labels)
        @ base_fields)
  | None | Some [] -> (
      match m.turn_ref with
      | None ->
          `Assoc
            ([ string_field "source" "keeper_chat_store"
             ; string_field "status" "history_without_turn_ref"
             ; string_field "reason"
                 "history row has no persisted turn_ref; no causal stream join is possible"
             ]
            @ stream_delivery_receipt_field "no_delivery_receipt"
            @ base_fields)
      | Some _ -> (
          match trace_block with
          | Some (Keeper_chat_blocks.Trace { trace }) when trace <> [] ->
              `Assoc
                ([ string_field "source" "backend_turn_trace"
                 ; string_field "status" "backend_trace_join"
                 ; string_field "reason"
                     "turn_ref joined to retained trajectory/internal-history events"
                 ; field "trace_event_count" (`Int (List.length trace))
                 ]
                @ stream_delivery_receipt_field "no_delivery_receipt"
                @ base_fields)
          | Some _ | None ->
              let reason =
                if trace_lookup_available then
                  "turn_ref persisted but no retained trajectory/internal-history events were available"
                else "history route served without trace enrichment"
              in
              `Assoc
                ([ string_field "source" "keeper_chat_store"
                 ; string_field "status" "history_without_stream_events"
                 ; string_field "reason" reason
                 ]
                @ stream_delivery_receipt_field "no_delivery_receipt"
                @ base_fields)))

let message_to_json ~trace_lookup_available ~trace_block (m : chat_message) : Yojson.Safe.t =
  `Assoc
    ([ ("id", `String m.id);
       ("role", `String (Role.to_label m.role));
       ("content", `String m.content);
       ("ts", `Float m.ts);
     ]
       @ Json_util.string_field_if_present "tool_call_id" m.tool_call_id
       @ Json_util.string_field_if_present "execution_id"
           (Option.map Ids.Execution_id.to_string m.execution_id)
       @ Json_util.string_field_if_present "tool_call_name" m.tool_call_name
       @ (match m.surface with
          | None -> []
          | Some s -> [ ("surface", Surface_ref.to_json s) ])
       @ Json_util.string_field_if_present "conversation_id" m.conversation_id
       @ Json_util.string_field_if_present "external_message_id" m.external_message_id
       @ Json_util.string_field_if_present "workspace_id" m.workspace_id
       @ speaker_fields m.speaker
       @ (match m.attachments with
          | None | Some [] -> []
          | Some atts ->
              (* History carries dimensions and a small blob marker;
                 image payloads are fetched only when requested. *)
              let att_json = List.map (fun (att : attachment) ->
                `Assoc ([
                  ("id", `String att.id);
                  ("type", `String att.att_type);
                  ("name", `String att.name);
                  ("size", `Int att.size);
                  ("mime_type", `String att.mime_type);
                  ("data", `String att.data);
                ]
                @ (match (att.width, att.height) with
                   | Some width, Some height ->
                     [ ("width", `Int width); ("height", `Int height) ]
                   | _ -> []))
              ) atts in
              [("attachments", `List att_json)])
       @ audio_fields m.audio
       @ [ ("stream_contract",
             chat_stream_contract_json
               ~trace_lookup_available
               ~trace_block m )
         ]
       @ blocks_fields_of_list (blocks_with_trace_block ~trace_block m)
       @ Json_util.string_field_if_present "turn_ref"
           (Option.map Ids.Turn_ref.to_string m.turn_ref)
       @ approval_lifecycle_fields m.approval_lifecycle
       (* Preserve the persisted provenance pair at the HTTP boundary.
          Dashboard convergence uses the same atomic identity as the
          append-once store instead of reconstructing a slot from role. *)
       @ (match m.delivery_provenance with
          | None -> []
          | Some provenance ->
              Keeper_chat_delivery_identity.delivery_provenance_fields
                provenance))
(* RFC-0233 §7: a turn's terminal assistant row is selected by exact persisted
   [turn_ref] ("<trace_id>#<absolute_turn>"). Direct/queued accepted-user rows
   are persisted before the turn exists, so they carry no [turn_ref]; they join
   through the same typed delivery key and the [Accepted_user] transcript slot.
   Tool rows are excluded — they carry only the call args, while the full tool
   I/O is surfaced by the tool-call store keyed on [execution_id]. *)
type turn_transcript = {
  user : chat_message list;
  assistant : chat_message list;
}

let transcript_of_messages (messages : chat_message list) ~turn_ref :
    turn_transcript =
  let matches_turn_ref (m : chat_message) =
    match m.turn_ref with
    | Some tr -> Ids.Turn_ref.equal tr turn_ref
    | None -> false
  in
  let terminal_delivery_keys =
    List.filter_map
      (fun (m : chat_message) ->
         match m.role, m.delivery_provenance with
         | ( (Role.Assistant | Role.Request_failure)
           , Some
               { Keeper_chat_delivery_identity.delivery_key
               ; transcript_slot = Keeper_chat_delivery_identity.Terminal_result
               } )
           when matches_turn_ref m ->
           Some delivery_key
         | (Role.Assistant | Role.System | Role.User | Role.Tool | Role.Request_failure), _ -> None)
      messages
  in
  let matches_accepted_user_delivery (m : chat_message) =
    match m.role, m.delivery_provenance with
    | ( Role.User
      , Some
          { Keeper_chat_delivery_identity.delivery_key
          ; transcript_slot = Keeper_chat_delivery_identity.Accepted_user
          } ) ->
      List.exists
        (Keeper_chat_delivery_identity.delivery_key_equal delivery_key)
        terminal_delivery_keys
    | (Role.Assistant | Role.System | Role.User | Role.Tool | Role.Request_failure), _ -> false
  in
  let user, assistant =
    List.fold_left
      (fun (user, assistant) (m : chat_message) ->
         match m.role with
         | Role.User when matches_turn_ref m || matches_accepted_user_delivery m ->
           m :: user, assistant
         | (Role.Assistant | Role.Request_failure) when matches_turn_ref m -> user, m :: assistant
         | Role.User | Role.Assistant | Role.System | Role.Tool | Role.Request_failure ->
           (* Tool rows join via execution_id in the tool-call store, not
              via the transcript. *)
           user, assistant)
      ([], []) messages
  in
  { user = List.rev user; assistant = List.rev assistant }

let transcript_line_to_json (m : chat_message) : Yojson.Safe.t =
  `Assoc
    [ ("role", `String (Role.to_label m.role))
    ; ("content", `String m.content)
    ; ("ts", `Float m.ts)
    ]

let turn_transcript_to_json ~keeper ~turn_ref (t : turn_transcript) :
    Yojson.Safe.t =
  (* [found] is false when no persisted row carries this turn_ref (old
     rows, rows outside the retained window, or a turn that produced no
     chat lines). The caller renders explicit absence, never a fabricated
     transcript. *)
  let found = t.user <> [] || t.assistant <> [] in
  `Assoc
    [ ("keeper", `String keeper);
      ("turn_ref", `String (Ids.Turn_ref.to_string turn_ref));
      ("found", `Bool found);
      ("source", `String "keeper_chat_store");
      ("user", `List (List.map transcript_line_to_json t.user));
      ("assistant", `List (List.map transcript_line_to_json t.assistant));
    ]
