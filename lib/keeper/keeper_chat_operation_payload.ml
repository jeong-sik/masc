type decoded_source =
  { submitted_by : string
  ; thread_id : string
  ; continuation_channel : Keeper_continuation_channel.t
  ; surface : Surface_ref.t
  ; channel : string
  ; channel_user_id : string
  ; channel_user_name : string
  ; channel_workspace_id : string
  ; conversation_id : string option
  ; external_message_id : string option
  ; workspace_id : string option
  ; extra_mentions : Keeper_identity.Keeper_id.t list
  ; user_row_origin : Keeper_chat_store.user_row_origin
  }

type decoded_input =
  { message : string
  ; user_blocks : Keeper_multimodal_input.user_input_block list
  ; turn_instructions : string option
  ; surface_context : Yojson.Safe.t option
  ; attachments : Keeper_chat_store.attachment list
  }

let source_schema = "masc.keeper_chat_operation.source.v1"
let input_schema = "masc.keeper_chat_operation.input.v1"

let strict_fields ~context ~expected = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length names <> List.length (List.sort_uniq String.compare names)
    then Error (context ^ " must contain unique fields")
    else
      (match List.find_opt (fun name -> not (List.mem name expected)) names with
       | Some name -> Error (Printf.sprintf "%s has unknown field %s" context name)
       | None ->
         (match List.find_opt (fun name -> not (List.mem_assoc name fields)) expected with
          | Some name -> Error (Printf.sprintf "%s is missing field %s" context name)
          | None -> Ok fields))
  | _ -> Error (context ^ " must be a JSON object")
;;

let input_to_json ~message ~user_blocks ~turn_instructions ~surface_context
      ~attachments =
  `Assoc
    [ "schema", `String input_schema
    ; "message", `String message
    ; "user_blocks", Keeper_multimodal_input.user_blocks_to_yojson user_blocks
    ; ( "turn_instructions"
      , match turn_instructions with None -> `Null | Some value -> `String value )
    ; ( "surface_context"
      , match surface_context with None -> `Null | Some value -> value )
    ; "attachments", Keeper_multimodal_input.attachments_to_yojson attachments
    ]
;;

let string_field ~context fields name =
  match List.assoc name fields with
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "%s field %s must be a string" context name)
;;

let option_string = function None -> "" | Some value -> value

let validate_source_route ~thread_id ~continuation_channel ~surface ~channel
      ~channel_user_id ~channel_workspace_id ~workspace_id =
  if String.trim thread_id = ""
  then Error "Keeper chat operation source thread_id must not be blank"
  else
    match continuation_channel, surface with
    | Keeper_continuation_channel.Dashboard _,
      ( Surface_ref.Dashboard _ | Surface_ref.Gate _ | Surface_ref.Agent
      | Surface_ref.Broadcast ) ->
      if String.trim channel_user_id = ""
      then Ok ()
      else Error "Dashboard Keeper chat operation cannot carry an external speaker"
    | ( Keeper_continuation_channel.Discord
          { guild_id
          ; channel_id
          ; parent_channel_id
          ; thread_id = route_thread
          ; user_id
          ; _
          }
      , Surface_ref.Discord
          { guild_id = surface_guild
          ; channel_id = surface_channel
          ; channel_name = _
          ; parent_channel_id = surface_parent
          ; thread_id = surface_thread
          } ) ->
      if not (String.equal (String.lowercase_ascii channel) "discord")
      then Error "Discord Keeper chat operation channel must be discord"
      else if not (String.equal channel_user_id user_id)
      then Error "Discord Keeper chat operation speaker does not match continuation"
      else if not (String.equal channel_workspace_id (option_string guild_id))
      then Error "Discord Keeper chat operation workspace does not match continuation"
      else if workspace_id <> guild_id
      then Error "Discord Keeper chat operation typed workspace does not match continuation"
      else if
        guild_id <> surface_guild
        || not (String.equal channel_id surface_channel)
        || parent_channel_id <> surface_parent
        || route_thread <> surface_thread
      then Error "Discord Keeper chat operation surface does not match continuation"
      else Ok ()
    | ( Keeper_continuation_channel.Slack
          { team_id; channel_id; thread_ts; user_id }
      , Surface_ref.Slack
          { team_id = surface_team
          ; channel_id = surface_channel
          ; thread_ts = surface_thread
          } ) ->
      if not (String.equal (String.lowercase_ascii channel) "slack")
      then Error "Slack Keeper chat operation channel must be slack"
      else if not (String.equal channel_user_id user_id)
      then Error "Slack Keeper chat operation speaker does not match continuation"
      else if not (String.equal channel_workspace_id (option_string team_id))
      then Error "Slack Keeper chat operation workspace does not match continuation"
      else if workspace_id <> team_id
      then Error "Slack Keeper chat operation typed workspace does not match continuation"
      else if
        team_id <> surface_team
        || not (String.equal channel_id surface_channel)
        || thread_ts <> surface_thread
      then Error "Slack Keeper chat operation surface does not match continuation"
      else Ok ()
    (* iMessage rides the generic gate surface ({!Surface_ref.Gate}), which
       carries its coordinates in an address assoc rather than in typed fields.
       So the pair check here is the connector label and the speaker; the
       conversation coordinate is checked where it is typed — the connector
       resolves the reply target against its own binding store at send time.
       Claiming a stronger check by reading strings out of the address would
       look like the Discord and Slack arms above without being one. *)
    | ( Keeper_continuation_channel.Imessage { user_id; _ }
      , Surface_ref.Gate { label = surface_label; _ } ) ->
      if not (String.equal (String.lowercase_ascii channel) "imessage")
      then Error "iMessage Keeper chat operation channel must be imessage"
      else if not (String.equal surface_label "imessage")
      then Error "iMessage Keeper chat operation surface does not match continuation"
      else if not (String.equal channel_user_id user_id)
      then Error "iMessage Keeper chat operation speaker does not match continuation"
      else Ok ()
    (* A Keeper reply route is internal by construction: it is created only
       when one Keeper asks another to run a turn, which is the Agent
       surface. There is no external speaker to attribute, so one carried
       here would name a person nobody routes the reply to. *)
    | Keeper_continuation_channel.Keeper _, Surface_ref.Agent ->
      if String.trim channel_user_id = ""
      then Ok ()
      else Error "Keeper-routed chat operation cannot carry an external speaker"
    | Keeper_continuation_channel.Unrouted _, _ ->
      Error "Keeper chat operation continuation must be routable"
    | (Keeper_continuation_channel.Dashboard _
      | Keeper_continuation_channel.Discord _
      | Keeper_continuation_channel.Slack _
      | Keeper_continuation_channel.Imessage _
      | Keeper_continuation_channel.Keeper _), _ ->
      Error "Keeper chat operation surface kind does not match continuation"
;;

let source_to_json ~submitted_by ~thread_id ~continuation_channel ~surface
      ~channel ~channel_user_id ~channel_user_name ~channel_workspace_id
      ~conversation_id ~external_message_id ~workspace_id
      ~extra_mentions
      ~user_row_origin =
  let ( let* ) = Result.bind in
  let* () =
    if String.trim submitted_by = ""
    then Error "Keeper chat operation source submitted_by must not be blank"
    else
      validate_source_route
        ~thread_id
        ~continuation_channel
        ~surface
        ~channel
        ~channel_user_id
        ~channel_workspace_id
        ~workspace_id
  in
  let* user_row_origin =
    match user_row_origin with
    | Keeper_chat_store.Needs_append -> Ok "needs_append"
    | Keeper_chat_store.Already_persisted_upstream -> Ok "already_persisted_upstream"
    | Keeper_chat_store.Already_persisted _ ->
      Error "Keeper chat operation source requires the exact persisted row identity"
  in
  Ok
    (`Assoc
       [ "schema", `String source_schema
       ; "submitted_by", `String submitted_by
       ; "thread_id", `String thread_id
       ; "continuation_channel", Keeper_continuation_channel.to_yojson continuation_channel
       ; "surface", Surface_ref.to_json surface
       ; "channel", `String channel
       ; "channel_user_id", `String channel_user_id
       ; "channel_user_name", `String channel_user_name
       ; "channel_workspace_id", `String channel_workspace_id
       ; ( "conversation_id"
         , match conversation_id with None -> `Null | Some value -> `String value )
       ; ( "external_message_id"
         , match external_message_id with None -> `Null | Some value -> `String value )
       ; ( "workspace_id"
         , match workspace_id with None -> `Null | Some value -> `String value )
       ; ( "extra_mentions"
         , `List
             (List.map
                (fun keeper_id ->
                   `String (Keeper_identity.Keeper_id.to_string keeper_id))
                extra_mentions) )
       ; "user_row_origin", `String user_row_origin
       ])
;;

let source_of_json json =
  let ( let* ) = Result.bind in
  let context = "Keeper chat operation source" in
  let* fields =
    strict_fields ~context
      ~expected:
        [ "schema"
        ; "submitted_by"
        ; "thread_id"
        ; "continuation_channel"
        ; "surface"
        ; "channel"
        ; "channel_user_id"
        ; "channel_user_name"
        ; "channel_workspace_id"
        ; "conversation_id"
        ; "external_message_id"
        ; "workspace_id"
        ; "extra_mentions"
        ; "user_row_origin"
        ]
      json
  in
  let* schema = string_field ~context fields "schema" in
  let* () =
    if String.equal schema source_schema
    then Ok ()
    else Error "Keeper chat operation source schema is unsupported"
  in
  let* submitted_by = string_field ~context fields "submitted_by" in
  let* () =
    if String.trim submitted_by = ""
    then Error "Keeper chat operation source submitted_by must not be blank"
    else Ok ()
  in
  let* thread_id = string_field ~context fields "thread_id" in
  let* continuation_channel =
    Keeper_continuation_channel.of_yojson (List.assoc "continuation_channel" fields)
  in
  let* surface = Surface_ref.of_json (List.assoc "surface" fields) in
  let* channel = string_field ~context fields "channel" in
  let* channel_user_id = string_field ~context fields "channel_user_id" in
  let* channel_user_name = string_field ~context fields "channel_user_name" in
  let* channel_workspace_id = string_field ~context fields "channel_workspace_id" in
  let optional_string name =
    match List.assoc name fields with
    | `Null -> Ok None
    | `String value when String.trim value <> "" -> Ok (Some value)
    | `String _ -> Error (Printf.sprintf "%s field %s must not be blank" context name)
    | _ -> Error (Printf.sprintf "%s field %s must be a string or null" context name)
  in
  let* conversation_id = optional_string "conversation_id" in
  let* external_message_id = optional_string "external_message_id" in
  let* workspace_id = optional_string "workspace_id" in
  let* extra_mentions =
    match List.assoc "extra_mentions" fields with
    | `List values ->
      let rec loop seen mentions = function
        | [] -> Ok (List.rev mentions)
        | `String value :: rest ->
          (match Keeper_identity.Keeper_id.of_string value with
           | None -> Error "Keeper chat operation source extra mention must not be blank"
           | Some keeper_id ->
             let canonical = Keeper_identity.Keeper_id.to_string keeper_id in
             if List.mem canonical seen
             then Error "Keeper chat operation source extra mentions must be unique"
             else loop (canonical :: seen) (keeper_id :: mentions) rest)
        | _ :: _ ->
          Error "Keeper chat operation source extra mentions must be strings"
      in
      loop [] [] values
    | _ -> Error "Keeper chat operation source extra_mentions must be an array"
  in
  let* user_row_origin =
    match List.assoc "user_row_origin" fields with
    | `String "needs_append" -> Ok Keeper_chat_store.Needs_append
    | `String "already_persisted_upstream" ->
      Ok Keeper_chat_store.Already_persisted_upstream
    | `String "already_persisted" ->
      Error "Keeper chat operation source cannot omit an already-persisted row id"
    | `String _ -> Error "Keeper chat operation source user_row_origin is unsupported"
    | _ -> Error "Keeper chat operation source user_row_origin must be a string"
  in
  let* () =
    validate_source_route
      ~thread_id
      ~continuation_channel
      ~surface
      ~channel
      ~channel_user_id
      ~channel_workspace_id
      ~workspace_id
  in
  Ok
    { submitted_by
    ; thread_id
    ; continuation_channel
    ; surface
    ; channel
    ; channel_user_id
    ; channel_user_name
    ; channel_workspace_id
    ; conversation_id
    ; external_message_id
    ; workspace_id
    ; extra_mentions
    ; user_row_origin
    }
;;

let input_of_json json =
  let ( let* ) = Result.bind in
  let context = "Keeper chat operation input" in
  let* fields =
    strict_fields ~context
      ~expected:
        [ "schema"
        ; "message"
        ; "user_blocks"
        ; "turn_instructions"
        ; "surface_context"
        ; "attachments"
        ]
      json
  in
  let* schema = string_field ~context fields "schema" in
  let* () =
    if String.equal schema input_schema
    then Ok ()
    else Error "Keeper chat operation input schema is unsupported"
  in
  let* message = string_field ~context fields "message" in
  let* user_blocks =
    Keeper_multimodal_input.parse_user_blocks
      (`Assoc [ "user_blocks", List.assoc "user_blocks" fields ])
  in
  let* turn_instructions =
    match List.assoc "turn_instructions" fields with
    | `Null -> Ok None
    | `String value -> Ok (Some value)
    | _ -> Error "Keeper chat operation input turn_instructions must be string or null"
  in
  let surface_context =
    match List.assoc "surface_context" fields with `Null -> None | value -> Some value
  in
  let* attachments =
    Keeper_multimodal_input.parse_attachments
      (`Assoc [ "attachments", List.assoc "attachments" fields ])
  in
  let* () =
    Keeper_multimodal_input.validate_attachment_references ~attachments
      user_blocks
  in
  Ok { message; user_blocks; turn_instructions; surface_context; attachments }
;;
