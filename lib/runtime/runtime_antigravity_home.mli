(** Persistent, operator-owned HOME layout for the official Antigravity CLI.

    The operator credential seeds the isolated HOME once. The resulting 0600
    regular file is then persistent runtime state so an OAuth refresh written by
    the CLI survives later turns. Turn-scoped MCP configuration is deliberately
    owned by the caller. *)

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
  | Invalid_managed_oauth of
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

type keychain_state =
  | Present
  | Provisioned
  | Unsupported  (** no usable [/usr/bin/security]; not macOS *)
  | Failed of string

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
    without symbolic links. It is copied only when the managed OAuth file does
    not exist; an existing managed file must itself be an effective-user-owned
    regular 0600 file and is never overwritten by preparation. *)

val home_dir : t -> string

val keychain_state : t -> keychain_state
(** Outcome of ensuring [<home>/Library/Keychains/login.keychain-db], the only
    path macOS resolves a HOME's login keychain from. Without it the CLI's
    token save finds no default keychain and macOS raises an operator dialog
    asking to create one; the CLI waits 5s and writes the token to a file
    instead, so a turn still completes. Preparation therefore never fails on
    this, and the caller reports the state rather than acting on it. *)

val keychain_state_to_string : keychain_state -> string

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

  val replace_keychain : home_dir:string -> string -> keychain_state
  (** Discard the keychain at the given path and build a fresh one. This is
      what a first preparation does when it finds a keychain an earlier
      process left behind, whose lock state nothing can ask about. *)

  val security_environment : home_dir:string -> string array
  (** The environment every [security] child runs under. HOME decides which
      keychain search list [create-keychain] appends to; pointing it at the
      managed home is what keeps the operator's own list out of it. *)
end
