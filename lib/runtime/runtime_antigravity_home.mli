(** Persistent, operator-owned HOME layout for the official Antigravity CLI.

    This module never reads or copies the OAuth token. It validates the
    operator token file and installs only a symbolic link inside the isolated
    HOME. Turn-scoped MCP configuration is deliberately owned by the caller. *)

type error =
  | Invalid_runtime_root of string
  | Invalid_owner_leaf of string
  | Unsafe_directory of
      { path : string
      ; detail : string
      }
  | Invalid_oauth_source of
      { path : string
      ; detail : string
      }
  | Invalid_oauth_link of
      { path : string
      ; detail : string
      }
  | Settings_write_failed of
      { path : string
      ; detail : string
      }

type t = private
  { home_dir : string
  ; workspace_dir : string
  ; settings_path : string
  ; mcp_config_path : string
  ; oauth_link_path : string
  }

val error_to_string : error -> string

val prepare
  :  runtime_root:string
  -> owner_leaf:string
  -> oauth_source:string
  -> (t, error) result
(** Create or verify the private Antigravity HOME below
    [<runtime_root>/official-clients/antigravity/<owner_leaf>]. Every managed
    directory is an exact 0700 real directory owned by the effective user.
    [oauth_source] must resolve to an effective-user-owned regular 0600 file.
    An unexpected existing OAuth target is rejected without replacement. *)

val child_environment : t -> (string * string) list
(** Exact environment overrides for the child. No API key or OAuth token value
    is included. *)

val settings_json : unit -> Yojson.Safe.t
(** Exact deny-by-default settings measured against Antigravity CLI 1.1.11. *)
