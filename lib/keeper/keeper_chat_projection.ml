(** Pure persisted-field and HTTP projections of resolved chat data. *)

open Keeper_chat_types
open Keeper_approval_lifecycle

let speaker_fields = function
  | None -> []
  | Some sp ->
      Json_util.string_field_if_present "speaker_id" sp.speaker_id
      @ Json_util.string_field_if_present "speaker_name" sp.speaker_name
      @ [ ("speaker_authority", `String (authority_label sp.speaker_authority)) ]

(* Nested ["audio"] assoc so the clip stays one unit on the
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
          | Some
              (Keeper_chat_blocks.Trace _
              | Keeper_chat_blocks.Text _
              | Keeper_chat_blocks.Heading _
              | Keeper_chat_blocks.Unordered_list _
              | Keeper_chat_blocks.Callout _
              | Keeper_chat_blocks.Table _
              | Keeper_chat_blocks.Code _
              | Keeper_chat_blocks.Mermaid _
              | Keeper_chat_blocks.Svg _
              | Keeper_chat_blocks.Voice _
              | Keeper_chat_blocks.Attach _
              | Keeper_chat_blocks.Image _
              | Keeper_chat_blocks.Link _
              | Keeper_chat_blocks.Fusion _
              | Keeper_chat_blocks.Status _
              | Keeper_chat_blocks.Thinking _)
          | None ->
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

let att_id_of_attachment (att : attachment) =
  let id_trimmed = String.trim att.id in
  if Result.is_ok (Attachment_store.parse_id id_trimmed)
  then Some id_trimmed
  else
    let data = String.trim att.data in
    let prefix = Attachment_store.url_prefix in
    let plen = String.length prefix in
    if String.starts_with ~prefix data
    then
      let rest = String.sub data plen (String.length data - plen) in
      let raw_id =
        match String.index_opt rest '?' with
        | Some idx -> String.sub rest 0 idx
        | None -> rest
      in
      if Result.is_ok (Attachment_store.parse_id raw_id) then Some raw_id else None
    else None

let attachment_json_of_meta (meta : Attachment_store.meta) : Yojson.Safe.t =
  let url = Attachment_store.url_of_id meta.id in
  let kind = Attachment_store.media_kind_to_string meta.kind in
  let name = Option.value meta.filename ~default:meta.id in
  let base_fields =
    match Attachment_store.meta_to_wire_json meta with
    | `Assoc fields -> fields
    | _ -> []
  in
  `Assoc
    (base_fields
     @ [ "type", `String kind
       ; "name", `String name
       ; "size", `Int meta.bytes
       ; "data", `String url
       ])

let attachment_json ?base_dir (att : attachment) : Yojson.Safe.t =
  match base_dir, att_id_of_attachment att with
  | Some bp, Some att_id ->
    (match Attachment_store.get_meta (Attachment_store.create ~base_path:bp) ~id:att_id with
     | Ok (Some meta) -> attachment_json_of_meta meta
     | Ok None | Error _ ->
       let url = Attachment_store.url_of_id att_id in
       let kind =
         let t = String.lowercase_ascii (String.trim att.att_type) in
         if t = "image" || t = "audio" || t = "document" then t
         else if String.starts_with ~prefix:"image/" (String.lowercase_ascii att.mime_type) then "image"
         else if String.starts_with ~prefix:"audio/" (String.lowercase_ascii att.mime_type) then "audio"
         else "document"
       in
       `Assoc
         ([ "id", `String att_id
          ; "attachment_id", `String att_id
          ; "url", `String url
          ; "type", `String att.att_type
          ; "kind", `String kind
          ; "name", `String att.name
          ; "filename", (if String.trim att.name = "" then `Null else `String att.name)
          ; "size", `Int att.size
          ; "bytes", `Int att.size
          ; "mime_type", `String att.mime_type
          ; "data", `String url
          ]
          @ (match att.width, att.height with
             | Some width, Some height ->
               [ "width", `Int width; "height", `Int height ]
             | _ -> [])))
  | None, Some att_id ->
    let url = Attachment_store.url_of_id att_id in
    `Assoc
      ([ "id", `String att_id
       ; "attachment_id", `String att_id
       ; "url", `String url
       ; "type", `String att.att_type
       ; "kind", `String (if att.att_type = "" then "document" else att.att_type)
       ; "name", `String att.name
       ; "filename", (if String.trim att.name = "" then `Null else `String att.name)
       ; "size", `Int att.size
       ; "bytes", `Int att.size
       ; "mime_type", `String att.mime_type
       ; "data", `String att.data
       ]
       @ (match att.width, att.height with
          | Some width, Some height -> [ "width", `Int width; "height", `Int height ]
          | _ -> []))
  | _, None ->
    `Assoc
      ([ "id", `String att.id
       ; "type", `String att.att_type
       ; "name", `String att.name
       ; "size", `Int att.size
       ; "mime_type", `String att.mime_type
       ; "data", `String att.data
       ]
       @ (match att.width, att.height with
          | Some width, Some height -> [ "width", `Int width; "height", `Int height ]
          | _ -> []))

let inferred_attachment_ids_from_row ~(blocks : chat_block list) (m : chat_message) =
  let from_blocks =
    match blocks with
    | [] -> []
    | bs ->
      Attachment_store.extract_att_ids
        (Yojson.Safe.to_string (Keeper_chat_blocks.blocks_to_yojson bs))
  in
  let from_content =
    match m.role with
    | Role.Tool | Role.Assistant -> Attachment_store.extract_att_ids m.content
    | Role.User | Role.System | Role.Request_failure -> []
  in
  let seen = Hashtbl.create 8 in
  List.filter
    (fun id ->
       if Hashtbl.mem seen id then false
       else (Hashtbl.add seen id (); true))
    (from_blocks @ from_content)

let message_to_json ?base_dir ?(omit_stream_contract = false) ~trace_lookup_available
    ~trace_block (m : chat_message) : Yojson.Safe.t =
  let effective_blocks = blocks_with_trace_block ~trace_block m in
  let explicit_atts = Option.value m.attachments ~default:[] in
  let explicit_att_ids =
    List.filter_map att_id_of_attachment explicit_atts
  in
  let derived_atts =
    match base_dir with
    | None -> []
    | Some bp ->
      let store = Attachment_store.create ~base_path:bp in
      inferred_attachment_ids_from_row ~blocks:effective_blocks m
      |> List.filter (fun id -> not (List.exists (String.equal id) explicit_att_ids))
      |> List.filter_map (fun id ->
           match Attachment_store.get_meta store ~id with
           | Ok (Some meta) -> Some (attachment_json_of_meta meta)
           | Ok None | Error _ -> None)
  in
  let all_att_json =
    List.map (attachment_json ?base_dir) explicit_atts @ derived_atts
  in
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
       @ (match all_att_json with
          | [] -> []
          | att_json -> [ ("attachments", `List att_json) ])
       @ audio_fields m.audio
       @ (if omit_stream_contract then [] else
          [ ("stream_contract",
             chat_stream_contract_json
               ~trace_lookup_available
               ~trace_block m )
          ])
       @ blocks_fields_of_list effective_blocks
       @ Json_util.string_field_if_present "turn_ref"
           (Option.map Ids.Turn_ref.to_string m.turn_ref)
       @ (match m.role, m.failure_kind with
          | Role.Request_failure, Some kind ->
            [ ("failure_kind", `String (Keeper_request_failure.Failure_kind.to_wire kind)) ]
          | (Role.User | Role.Assistant | Role.System | Role.Tool), _
          | Role.Request_failure, None -> [])
       @ approval_lifecycle_fields m.approval_lifecycle
       (* Preserve the persisted provenance pair at the HTTP boundary.
          Dashboard convergence uses the same atomic identity as the
          append-once store instead of reconstructing a slot from role. *)
       @ (match m.delivery_provenance with
          | None -> []
          | Some provenance ->
              Keeper_chat_delivery_identity.delivery_provenance_fields
                provenance))
(* A turn's terminal assistant row is selected by exact persisted
   [turn_ref] ("<trace_id>#<absolute_turn>"). Direct/queued accepted-user rows
   are persisted before the turn exists, so they carry no [turn_ref]; they join
   through the same typed delivery key and the [Accepted_user] transcript slot.
   Tool rows are excluded — they carry only the call args, while the full tool
   I/O is surfaced by the tool-call store keyed on [execution_id]. *)
type turn_transcript = {
  user : chat_message list;
  assistant : chat_message list;
}

let user_matches_turn ~messages ~turn_ref =
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
               ; transcript_slot = (Keeper_chat_delivery_identity.Terminal_result | Keeper_chat_delivery_identity.Settled_failure)
               } )
           when matches_turn_ref m ->
           Some delivery_key
         | (Role.Assistant | Role.System | Role.User | Role.Tool | Role.Request_failure),
           ( None
    | Some
        { Keeper_chat_delivery_identity.transcript_slot =
            ( Keeper_chat_delivery_identity.Accepted_user
            | Keeper_chat_delivery_identity.Tool_call _
            | Keeper_chat_delivery_identity.Tool_delivery _
            | Keeper_chat_delivery_identity.Terminal_result
            | Keeper_chat_delivery_identity.Settled_failure
            | Keeper_chat_delivery_identity.Approval_request
            | Keeper_chat_delivery_identity.Approval_resolution
            | Keeper_chat_delivery_identity.Approval_replay
            | Keeper_chat_delivery_identity.Approval_replay_correction
            | Keeper_chat_delivery_identity.Approval_continuation
            | Keeper_chat_delivery_identity.Autonomous_input_binding _ )
        ; _
        } ) -> None)
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
    | (Role.Assistant | Role.System | Role.User | Role.Tool | Role.Request_failure),
      ( None
    | Some
        { Keeper_chat_delivery_identity.transcript_slot =
            ( Keeper_chat_delivery_identity.Accepted_user
            | Keeper_chat_delivery_identity.Tool_call _
            | Keeper_chat_delivery_identity.Tool_delivery _
            | Keeper_chat_delivery_identity.Terminal_result
            | Keeper_chat_delivery_identity.Settled_failure
            | Keeper_chat_delivery_identity.Approval_request
            | Keeper_chat_delivery_identity.Approval_resolution
            | Keeper_chat_delivery_identity.Approval_replay
            | Keeper_chat_delivery_identity.Approval_replay_correction
            | Keeper_chat_delivery_identity.Approval_continuation
            | Keeper_chat_delivery_identity.Autonomous_input_binding _ )
        ; _
        } ) -> false
  in
  fun (m : chat_message) ->
    match m.role with
    | Role.User -> matches_turn_ref m || matches_accepted_user_delivery m
    | Role.Assistant | Role.System | Role.Tool | Role.Request_failure -> false

let transcript_of_messages (messages : chat_message list) ~turn_ref :
    turn_transcript =
  let matches_turn_ref (m : chat_message) =
    Option.exists (Ids.Turn_ref.equal turn_ref) m.turn_ref
  in
  let matches_user = user_matches_turn ~messages ~turn_ref in
  let user, assistant =
    List.fold_left
      (fun (user, assistant) (m : chat_message) ->
         match m.role with
         | Role.User when matches_user m ->
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
  (* [found] describes the selected user/assistant arrays. The v2 HTTP
     producer owns the strict retained-history read that precedes this
     projection; formatting a supplied list is not itself storage proof. *)
  let found = t.user <> [] || t.assistant <> [] in
  `Assoc
    [ ("schema", `String "masc.keeper.turn-transcript.v2");
      ("keeper", `String keeper);
      ("turn_ref", `String (Ids.Turn_ref.to_string turn_ref));
      ("found", `Bool found);
      ("source", `String "keeper_chat_store");
      ("user", `List (List.map transcript_line_to_json t.user));
      ("assistant", `List (List.map transcript_line_to_json t.assistant));
    ]
