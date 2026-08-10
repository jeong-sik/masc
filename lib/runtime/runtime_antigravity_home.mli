(** Persistent, operator-owned HOME layout for the official Antigravity CLI.

    The operator credential is read through the owned-file boundary and copied
    into the isolated HOME as an exact 0600 snapshot. Turn-scoped MCP
    configuration is deliberately owned by the caller. *)

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
  | Invalid_oauth_copy of
      { path : string
      ; detail : string
      }
  | Settings_write_failed of
      { path : string
      ; detail : string
      }
  | Mcp_config_write_failed of
      { path : string
      ; detail : string
      }
  | Mcp_config_cleanup_failed of
      { path : string
      ; detail : string
      }

type t

val error_to_string : error -> string

val prepare
  :  runtime_root:string
  -> owner_leaf:string
  -> oauth_source:string
  -> (t, error) result
(** Create or verify the private Antigravity HOME below
    [<runtime_root>/official-clients/antigravity/<owner_leaf>]. Every managed
    directory is an exact 0700 real directory owned by the effective user.
    [oauth_source] must be an effective-user-owned regular 0600 file reached
    without symbolic links. *)

val home_dir : t -> string

val publish_mcp_config : t -> Yojson.Safe.t -> (unit, error) result
(** Atomically publish one turn capability as an exact 0600 MCP config. *)

val clear_mcp_config : t -> (unit, error) result
(** Remove the turn capability after the listener has stopped. *)

module For_testing : sig
  type paths =
    { settings_path : string
    ; mcp_config_path : string
    ; oauth_path : string
    }

  val paths : t -> paths
  val settings_json : unit -> Yojson.Safe.t
end
