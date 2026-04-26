(* ── 6. Serialization (Yojson Helpers) ───────────────────────── *)

let media_attachment_to_json (m : media_attachment) : Yojson.Safe.t =
  `Assoc [ "url", `String m.url; "content_type", `String m.content_type ]
;;

let payload_content_to_json (p : payload_content) : Yojson.Safe.t =
  let text_field =
    match p.text with
    | Some t -> [ "text", `String t ]
    | None -> []
  in
  let media_field =
    match p.media with
    | [] -> []
    | m -> [ "media", `List (List.map media_attachment_to_json m) ]
  in
  let audio_field =
    match p.audio_blob with
    | Some a -> [ "audio_blob", `String a ]
    | None -> []
  in
  `Assoc (text_field @ media_field @ audio_field)
;;

let event_type_to_string = function
  | Message -> "message"
  | Voice_chunk -> "voice_chunk"
  | Presence -> "presence"
  | Control -> "control"
;;

let outbound_event_to_json (e : outbound_event) : Yojson.Safe.t =
  let base =
    [ "event_id", `String e.event_id
    ; "target_channel", `String e.target_channel
    ; "source_agent", `String e.source_agent
    ; "event_type", `String (event_type_to_string e.event_type)
    ; "content", payload_content_to_json e.content
    ]
  in
  let room =
    match e.target_room_id with
    | Some r -> [ "target_room_id", `String r ]
    | None -> []
  in
  let stats =
    match e.turn_stats with
    | Some s ->
      [ ( "turn_stats"
        , `Assoc
            [ "model_used", `String s.model_used
            ; "duration_ms", `Int s.duration_ms
            ; "tokens_used", `Int s.tokens_used
            ] )
      ]
    | None -> []
  in
  `Assoc (base @ room @ stats)
;;

let control_action_to_json = function
  | Mute -> `String "mute"
  | Unmute -> `String "unmute"
  | Set_Rate_Limit n -> `Assoc [ "action", `String "set_rate_limit"; "limit", `Int n ]
;;

let control_event_to_json (c : control_event) : Yojson.Safe.t =
  let base =
    [ "event_id", `String c.event_id
    ; "target_channel", `String c.target_channel
    ; "action", control_action_to_json c.action
    ]
  in
  let room =
    match c.target_room_id with
    | Some r -> [ "target_room_id", `String r ]
    | None -> []
  in
  let dur =
    match c.duration_sec with
    | Some d -> [ "duration_sec", `Int d ]
    | None -> []
  in
  let rsn =
    match c.reason with
    | Some r -> [ "reason", `String r ]
    | None -> []
  in
  `Assoc (base @ room @ dur @ rsn)
;;
