(** Pure immutable state transition for provider registration. *)

type provider_defaults =
  { kind : Provider_config.provider_kind
  ; base_url : string
  ; api_key_env : string
  ; request_path : string
  ; request_path_by_identity_kind : (Provider_config.provider_kind * string) list
        (** Per-wire paths for a provider that speaks more than one.
            [request_path] is the default wire's; a caller resolved onto a
            second wire looks here first, or it sends the default wire's path
            to a host with no such route (#33200 lane: ollama_cloud on the
            OpenAI wire sent /v1 + /api/chat and got 404). *)
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
