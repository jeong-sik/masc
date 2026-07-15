type attachment =
  { id : string
  ; attachment_type : string
  ; name : string
  ; size : int
  ; mime_type : string
  ; data : string
  }
[@@deriving yojson, eq]

type user_media_block =
  { attachment_id : string
  ; name : string
  ; mime_type : string
  ; size : int option
  }
[@@deriving yojson, eq]

type user_input_block =
  | User_text of string
  | User_image of user_media_block
  | User_document of user_media_block
  | User_audio of user_media_block
[@@deriving yojson, eq]

type speaker_authority =
  | Owner
  | External
[@@deriving yojson, eq]

type speaker =
  { speaker_id : string option
  ; speaker_name : string option
  ; speaker_authority : speaker_authority
  }
[@@deriving yojson, eq]

type connector_context =
  { connector : string
  ; workspace_id : string
  ; actor_id : string option
  ; actor_name : string option
  }
[@@deriving yojson, eq]

type projection =
  { user_content : string
  ; surface : Surface_ref.t
  ; conversation_id : string option
  ; external_message_id : string option
  ; speaker : speaker
  }
[@@deriving yojson, eq]

type t =
  { execution_prompt : string
  ; attachments : attachment list
  ; user_blocks : user_input_block list
  ; turn_instructions : string option
  ; connector_context : connector_context option
  ; continuation_channel : Keeper_continuation_channel.t
  ; projection : projection
  }
[@@deriving yojson, eq]

let validate_media media =
  if String.equal media.attachment_id ""
  then Error "direct user media requires attachment_id"
  else
    match media.size with
    | Some size when size < 0 -> Error "direct user media size must be non-negative"
    | None | Some _ -> Ok ()
;;

let validate_block = function
  | User_text "" -> Error "direct user text must be non-empty"
  | User_text _ -> Ok ()
  | User_image media | User_document media | User_audio media -> validate_media media
;;

let validate value =
  let ( let* ) = Result.bind in
  let* () =
    if String.equal value.execution_prompt ""
    then Error "direct execution_prompt must be non-empty"
    else Ok ()
  in
  let* () =
    List.fold_left
      (fun result (attachment : attachment) ->
         let* () = result in
         if attachment.size < 0
         then Error "direct attachment size must be non-negative"
         else if String.equal attachment.id "" || String.equal attachment.data ""
         then Error "direct attachment requires id and data"
         else Ok ())
      (Ok ())
      value.attachments
  in
  let* () =
    List.fold_left
      (fun result block ->
         let* () = result in
         validate_block block)
      (Ok ())
      value.user_blocks
  in
  match value.connector_context with
  | None -> Ok ()
  | Some connector
    when String.equal connector.connector "" || String.equal connector.workspace_id "" ->
    Error "direct connector context requires connector and workspace_id"
  | Some _ -> Ok ()
;;
