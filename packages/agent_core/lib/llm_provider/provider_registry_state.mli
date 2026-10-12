(** Pure immutable state transition for provider registration. *)

type provider_defaults =
  { kind : Provider_config.provider_kind
  ; base_url : string
  ; request_path : string
  ; requires_api_key : bool
  }

type entry =
  { name : string
  ; defaults : provider_defaults
  ; max_context : int option
  ; capabilities : Capabilities.capabilities
  ; is_available : unit -> bool
  }

type event =
  | Register of entry
  | Unregister of string

type t

val empty : t
val apply : t -> event -> t
val find : string -> t -> entry option
val all : t -> entry list
