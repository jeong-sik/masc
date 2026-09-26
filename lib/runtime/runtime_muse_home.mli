(** Managed Muse configuration and credential generations shared by all Keepers
    selecting the same account HOME. Native session/data directories stay in
    that HOME; only XDG_CONFIG_HOME points at the managed generation. *)
type t

type error =
  | Invalid_account_home of string
  | Sign_in_required
  | State_unavailable of string

val error_to_string : error -> string

val prepare : account_home:string -> (t, error) result
(** Import the selected account's [.config/muse/auth.json] on first use or
    when its exact source bytes change. Reuse an unchanged source's generation
    without replacing credentials the vendor refreshed there. Publication of
    a new generation is atomic and serialized per selected account. No hooks,
    plugins or permission choices from source settings are imported. *)

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
