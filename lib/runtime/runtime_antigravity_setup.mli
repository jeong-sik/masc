(** Explicit Antigravity account selection, never called by catalog inspection. *)
type t
type error = Private_home_unavailable | Sign_in_required | Unsafe_credential
  | Command_failed | Invalid_catalog | Keychain_unavailable
val error_message : error -> string
val prepare : runtime_root:string -> account_id:string -> (t, error) result
val home_dir : t -> string
val environment : t -> string array
val import_signed_in : source_home:string -> t -> (unit, error) result
(** Read only the canonical CLI OAuth file or the explicitly named macOS
    gemini/antigravity keychain item, then copy it into this private HOME.
    Never modify the source; call only after account selection. *)
val capture_login : t -> (unit, error) result
(** Capture authentication created by an explicit interactive [agy] sign-in. *)
val credential_reference : t -> (Runtime_schema.credential, error) result
type model = { id : string; label : string }
val parse_models : string -> (model list, error) result
val discover_models : cli_path:string -> timeout_s:float -> t -> (model list, error) result
val models_json : model list -> Yojson.Safe.t

type context_observation = Unknown_context | Observed_context of int
val parse_context : model:model -> cli_version:string -> string -> (context_observation, error) result
(** Parse the official status-line payload from this selected account's fresh
    no-prompt CLI session. The caller binds the fresh capture to the requested
    model slug and CLI version; model labels are matched exactly, never guessed.
    Missing/zero context is explicitly unknown, not a provider API maximum.
    Nonzero token usage rejects the zero-turn metadata observation. *)

module For_testing : sig
  val import_with :
    read_keychain:(path:string -> Apple_keychain.observation) ->
    clear_keychain:(path:string -> (unit, unit) result) ->
    source_home:string -> t -> (unit, error) result
end
