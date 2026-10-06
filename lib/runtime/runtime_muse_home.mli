(** Managed Muse configuration and credential generations shared by all Keepers
    selecting the same account HOME. Native session/data directories stay in
    that HOME; only XDG_CONFIG_HOME points at the managed generation. *)
type t

(** Why the selected account has no sign-in masc can use. Each one is answered
    by signing in again through one of masc's Muse sign-ins ([/login muse] in
    the TUI, or [masc runtime-account-login --client muse] from the installer),
    which run the client with the file credential backend. *)
type sign_in_gap =
  | No_file_sign_in
      (** No auth.json, or one without Meta credentials. *)
  | Keychain_sign_in
      (** auth.json says the secrets live in the macOS Keychain
          ([storage: "keychain"]). A managed generation copies files only, so
          the child would find no token. *)
  | Unsupported_credential_storage of string
      (** A [storage] value masc does not know, kept as written. *)

type error =
  | Invalid_account_home of string
  | Sign_in_required of sign_in_gap
  | State_unavailable of string

val error_to_string : error -> string

val prepare : account_home:string -> (t, error) result
(** Import the selected account's [.config/muse/auth.json] on first use or
    when its exact source bytes change. Reuse an unchanged source's generation
    without replacing credentials the vendor refreshed there, while its
    [settings.json] is the current managed settings: the [:ask-me] profile
    with every bundled observer agent turned off. A generation with other
    settings is replaced by a new one that carries its credentials, so a
    policy change reaches signed-in accounts without a new sign-in. The Meta slot
    must be non-empty, and its [storage] marker must be absent or ["file"]:
    ["keychain"] is [Sign_in_required Keychain_sign_in] and any other value is
    [Unsupported_credential_storage]. Whether the slot actually holds a secret
    is not checked here; a slot without one fails at the client's own
    authentication. Publication of
    a new generation is atomic and serialized per selected account. No hooks,
    plugins or permission choices from source settings are imported. Owned
    account and credential-parent directories must not be group/other writable. *)

val source_auth_path : account_home:string -> string
(** The auth document the vendor CLI writes when signing in under
    [account_home]; {!prepare} imports it. *)

val auth_path : string option -> string option
(** The auth document the vendor CLI reads for a selected [account_home], or
    with none for the environment it inherits. [None] when that environment
    names no config home. *)

val account_home : t -> string
(** Exact configured source account spelling, distinct from the canonical
    filesystem ownership root used during preparation. *)

val physical_home : t -> string
(** The resolved physical account root used to prepare this generation. Child
    HOME and data/state/cache roots use it so retargeting the configured symlink
    cannot split credential and session storage across accounts. *)

val config_home : t -> string
val private_tmpdir : t -> string
(** Override the child's TMPDIR as well: the vendor sandbox permits its temp
    root, so inheriting a shared host temp tree would enlarge that boundary. *)
val account_revision : t -> string
(** Opaque import-generation identity. Include it in the durable session
    binding so an external sign-in cannot resume the prior account's session.
    It is not a credential digest. *)

val prepare_native_workspace :
  runtime_root:string -> keeper_name:string -> account_home:string ->
  (string, error) result
(** Private durable native-client workspace for endpoint-owned Keepers. This
    is independent of both guest filesystem coordinates and config storage. *)

module For_testing : sig
  val prepare_with_store_sync : sync_store:(string -> unit) -> account_home:string -> (t, error) result
  val check_directory_stat : private_:bool -> Unix.stats -> (unit, error) result
  val check_file_snapshot : Fs_compat.owned_regular_file_snapshot -> (unit, error) result
  val ensure_directory_with_sync : sync:(string -> unit) -> private_:bool -> string -> (unit, error) result
end
