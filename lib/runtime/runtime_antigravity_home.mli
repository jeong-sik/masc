(** Persistent, operator-owned HOME layout for the official Antigravity CLI.

    The account a CLI login file names (see {!Runtime_antigravity_oauth_credential})
    reuses a private account generation, keeping native OAuth refreshes even
    when source credentials rotate or the CLI rewrites the file's shape. A changed
    selected principal publishes a fresh opaque generation so another account
    cannot reuse the prior account's HOME or session.
    Old in-flight generations remain intact. Turn-scoped MCP configuration is
    owned by the caller.

    Every preparation takes a {!Runtime_account_access.host_account}: a HOME
    holds a copy of a credential of the host, so a multi-account process
    prepares none (multi-account plan D3b). *)

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
  | Unrecognized_oauth_source of
      { path : string
      ; rejection : Runtime_antigravity_oauth_credential.rejection
      }
      (** The source file was read but matches no known CLI login shape. *)
  | Invalid_managed_oauth of
      { path : string
      ; detail : string
      }
  | Unrecognized_managed_oauth of
      { path : string
      ; rejection : Runtime_antigravity_oauth_credential.rejection
      }
      (** The managed login file matches no known CLI login shape. *)
  | Unrecognized_managed_keychain of
      { path : string
      ; rejection : Runtime_antigravity_oauth_credential.keychain_rejection
      }
      (** The managed login keychain at [path] holds a readable item that
          does not decode, as go-keyring reads it, to a known CLI login. *)
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
  | Native_tools_refused of Runtime_account_access.native_refusal
      (** {!prepare_native_tools} was asked for a posture this process runs no
          model turn with. No native rule was written, and the settings of an
          earlier turn stay as they were. *)

type keychain_state =
  | Present
  | Provisioned
  | Unsupported  (** no usable [/usr/bin/security]; not macOS *)
  | Failed of string

type t

val error_to_string : error -> string

val keeper_owner_leaf : keeper_name:string -> oauth_source:string -> string
(** Stable account boundary for a Keeper. Identity uses the configured source
    path, never token bytes, so refresh preserves the account's managed state. *)

val keeper_home_dir : runtime_root:string -> owner_leaf:string -> string
(** The owner HOME root below
    [<runtime_root>/official-clients/antigravity/<owner_leaf>]. Pure path
    composition; does not create anything. *)

val keeper_prepare_lock_path : runtime_root:string -> owner_leaf:string -> string
(** The sibling preparation lock
    [<runtime_root>/antigravity-<owner_leaf>.prepare.lock] that
    [with_prepared_account] holds across account generation. Pure path
    composition; does not create anything. *)

val prepare
  :  host:Runtime_account_access.host_account
  -> runtime_root:string
  -> owner_leaf:string
  -> oauth_source:string
  -> (t, error) result
(** Create or verify the private Antigravity HOME below
    [<runtime_root>/official-clients/antigravity/<owner_leaf>/<generation>]. Every
    managed directory is an exact 0700 real directory owned by the effective user.
    [oauth_source] must be an effective-user-owned regular 0600 file reached
    without symbolic links. The private source is read under the preparation
    lock before account directories are created. The login file must name its
    account in a known CLI shape. A changed principal seeds a fresh
    generation; token refreshes for the same principal preserve the existing
    effective-user-owned regular 0600 managed credential only when its principal
    still matches the generation record. A readable managed login-keychain item
    naming another principal refuses the same way, since keyring-first CLI reads
    would resume that account, and so does a readable item that does not
    decode to a known login. A missing or unreadable item leaves the file
    authoritative; an item the CLI wrote is unreadable here, because its ACL
    admits only /usr/bin/security. The principal is the login's email, so a
    source login for an address Google gave to another account selects the
    previous holder's generation, and its managed credential stays in use.
    A missing pointer is first-time setup
    only in an empty owner store; populated stores refuse without reseeding.
    This local continuity
    identity is not cryptographic authentication or readiness evidence. Missing
    or corrupt current generation state refuses instead of recreating it. The
    returned actual HOME is the opaque account identity for session binding. *)

val prepare_account
  :  host:Runtime_account_access.host_account
  -> runtime_root:string
  -> owner_leaf:string
  -> oauth_source:string
  -> (t, error) result
(** Validate and select the account generation without changing its permissions.
    Keeper uses this before comparing session identity: a losing concurrent
    planner must not reset an active client's policy. Before launching a client,
    its admitted owner must publish the intended policy with [prepare_native_tools]. *)

val prepare_for_login
  : host:Runtime_account_access.host_account -> runtime_root:string -> owner_leaf:string -> (t, error) result
(** Prepare the private official-client HOME without fabricating an OAuth seed.
    Only an explicit sign-in action may use it to launch the interactive CLI. *)
val oauth_path : t -> string
(** Private native reference for setup import; never include in HTTP receipts. *)

val home_dir : t -> string

val mcp_server_name : string
(** The MCP server name every Antigravity caller starts its bridge under. The
    policy opens [<appDataDir>/mcp/<this name>], where agy keeps the lazily
    loaded tools' arguments, and grants every tool of this server. *)

type native_workspace = Shared_workspace of string | Private_workspace

val canonical_workspace : string -> (string, error) result
(** Absolute directory without symbolic links or permission-pattern syntax. *)

val prepare_native_workspace : t -> workspace:native_workspace -> (string, error) result
(** Validate the shared cwd or prepare its private directory without publishing
    any permission rules. Safe for a candidate that has not claimed its turn. *)

val prepare_native_tools
  : t -> posture:Runtime_native_tools.posture -> workspace:native_workspace
  -> additional_workspaces:string list -> (string, error) result
(** Apply native permissions to the selected workspace and return its cwd.
    Endpoint-owned trees use [Private_workspace], an isolated host directory;
    this does not claim native access to the endpoint's actual files.
    In every posture a root that holds the runtime root this HOME was
    prepared under is refused, and so is an additional root inside it. For a
    Keeper that root is the masc state directory, which holds every Keeper's
    credentials. A refusal leaves the published settings unchanged.
    Every posture names the masc tool schema folder and denies the config
    folder and the token file by exact path (RFC-0490 2.2). Until L3,
    [Native_none] also keeps the all-files [read_file] deny, so its schema allow remains
    shadowed and no read becomes an Ask. Its workspace root denies remain
    for L3, and a root that holds the HOME is refused.
    Read posture denies commands and writes; full permits sandboxed effects.
    Both deny native network tools. The caller must enable the CLI sandbox;
    no command allow rule is emitted because it would grant sandbox escapes
    too. Unsandboxed requests retain the vendor's interactive approval gate. *)

val prepare_read_hook
  : t -> cwd:string -> additional_workspaces:string list -> (unit, error) result
(** Publish a native read guard before launching the admitted Keeper client.
    The guard must be installed beside the running executable; PATH is not
    searched. It returns out-of-scope reads as tool errors before headless Ask
    can end the turn, delegating permitted reads to the existing settings.
    The settings, including [Native_none]'s broad deny, are unchanged. The
    caller supplies the canonical roots returned by native policy preparation.
    Missing/unusable helper binaries refuse preparation. *)

val prepare_native
  : host:Runtime_account_access.host_account
  -> runtime_root:string -> owner_leaf:string -> oauth_source:string
  -> posture:Runtime_native_tools.posture -> workspace:native_workspace
  -> additional_workspaces:string list -> (t * string, error) result
(** Prepare persistent account storage and atomically publish the intended
    native policy once, returning the managed HOME and native cwd. Unlike
    [prepare] followed by [prepare_native_tools], this never temporarily resets
    overlapping native readers to the default permissions. Existing native
    credential refresh survives repeated preparation. *)

val write_context_observation_settings : t -> command:string -> (unit, error) result
(** Metadata-only setup for a fresh disposable HOME: no MCP allowance and no
    native file/command access; only the official status-line callback runs. *)


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

val forget_prepared_below : runtime_root:string -> unit
(** Forget the first-preparation claims of the homes below [runtime_root]. A
    caller that removes a root it prepared once (a disposable one) calls this
    with the removal, or the process keeps one table entry per root for as
    long as it runs. Homes below other roots keep their claims. *)

module For_testing : sig
  val ensure_private_child_with_sync
    : sync_parent:(string -> unit) -> string -> string -> (string, error) result

  val prepare_account_with_store_sync
    : sync_store:(string -> unit) -> ?read_keychain:(path:string -> Apple_keychain.observation)
    -> ?sync_pointer_file:(string -> unit) -> ?sync_pointer_parent:(string -> unit)
    -> runtime_root:string -> owner_leaf:string
    -> oauth_source:string -> unit -> (t, error) result
  (** Test seam over [prepare_account]. [sync_store] confirms prepared HOME
      directories and the pointer directory before reusing a visible generation. [read_keychain] observes the
      managed login-keychain item and defaults to [Apple_keychain.read].
      [sync_pointer_file] and [sync_pointer_parent] inject failures into the
      atomic pointer writer before and after rename; both default to strict
      filesystem synchronization. A post-rename failure retains its referenced
      generation for the next preparation to confirm. *)

  type paths =
    { settings_path : string
    ; mcp_config_path : string
    ; oauth_path : string
    }

  val paths : t -> paths
  val settings_json : t -> (Yojson.Safe.t, error) result
  (** The default ([Native_none]) policy this HOME is prepared with. *)

  val prepared_count_below : runtime_root:string -> int
  (** How many homes below [runtime_root] hold a first-preparation claim. *)

  val replace_keychain : home_dir:string -> string -> keychain_state
  (** Discard the keychain at the given path and build a fresh one. This is
      what a first preparation does when it finds a keychain an earlier
      process left behind, whose lock state nothing can ask about. *)

  val security_environment : home_dir:string -> string array
  (** The environment every [security] child runs under. HOME decides which
      keychain search list [create-keychain] appends to; pointing it at the
      managed home is what keeps the operator's own list out of it. *)
end

val is_keeper_prepare_lock_name : string -> bool
(** Whether [name] is a basename {!keeper_prepare_lock_path} makes. *)
