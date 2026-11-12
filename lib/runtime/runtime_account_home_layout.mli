(* HIGH-RISK-UNREVIEWED: the spelling of a login home is the identity of the
   account an official client keeps there. A second spelling of the same
   directory is a second account, and a home under the wrong runtime root is
   another person's account. *)

(** Where the login of an official client keeps an account (design 4.1 and
    5.4). This is the one place that spells the path of a login home: the
    login that makes it ({!Runtime_setup_login_client}), the verification
    that reads it and {!Runtime_account_access}, which lets a CLI start on it,
    all compute it here.

    The home of an account is
    [<runtime root>/official-clients/<client>/<account id>], spelled from the
    real path of the runtime root. Claude Code keeps its keychain entry under a
    hash of that spelling. The runtime root of the operator is the [.masc]
    directory of the base path. The runtime root of a person is
    [<.masc>/accounts/<namespace>], under the namespace their admission fixed,
    which no other person is given ({!Authz_principal_state.find_namespace}). *)

(** A client that signs in to a home of its own. *)
type client =
  | Codex_home
  | Claude_home
  | Muse_home

val clients_dir : string
val client_dir : client -> string

(** The directory under the [.masc] directory that holds the runtime roots of
    the persons. *)
val accounts_dir : string

(** [<.masc>/accounts/<namespace>]. It reads and makes nothing. *)
val person_runtime_root
  :  base_path:string
  -> namespace:Authz_types.Account_home_namespace.t
  -> string

(** Whether [home] is under {!accounts_dir} of [base_path], where the runtime
    roots of the persons are. Both paths are read as spelled and by their real
    path, the deepest part that is there resolved and the parts under it as
    spelled, so a link, another case of a name on a volume that ignores case,
    or a home that is not made yet still leads under it. It reads real paths
    and makes nothing. *)
val under_persons : base_path:string -> string -> bool

(** Whether {!accounts_dir} of [base_path] is there: a login of a person made
    it for the runtime roots of the persons, and only the operator removes
    it. Whatever has that name counts, an empty directory, a link or a file,
    so the answer needs no listing, which could end early on a read error and
    look empty. [Ok false] only when the name is not there. [Error] when the
    path to it could not be read. It reads one name and makes nothing. *)
val persons_remain : base_path:string -> (bool, Unix.error) result

(** The home of [account_id] of [client] under [runtime_root], spelled from the
    real path of [runtime_root]. It reads only that real path and makes
    nothing. [runtime_root] is absolute and [account_id] is one path leaf. *)
val home : runtime_root:string -> client -> account_id:string -> (string, string) result
