(** Boot-time policy for the optional Slack API connector. Browser Lane and
    the independent OAuth provider registration do not consult this policy. *)
type error =
  | Unreadable of string
  | Invalid_toml of string
  | Invalid_enabled of string

val error_to_string : error -> string
val load : path:string -> (Env_config_slack.connector_state, error) result

(** Install a disabled state on invalid/unreadable input and report its typed
    failure. Missing file/key means enabled; a present non-boolean never does. *)
val configure : config_root:string -> unit
