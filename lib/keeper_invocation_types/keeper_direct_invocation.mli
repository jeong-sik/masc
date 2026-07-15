(** Immutable, replayable input for the direct Keeper executor. Runtime
    callbacks and functions are deliberately outside this value. *)

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

val validate : t -> (unit, string) result
