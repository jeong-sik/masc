(* HIGH-RISK-UNREVIEWED: this module reads what the boot judgment of the account
   mode decides on. Reading a file that is there as absent boots a rolled-back
   multi-account installation as a single user. *)

(** What the boot reads for {!Authz_boot_mode.judge}, and what it does with the
    answer (multi-account plan, A2 scope).

    It reads three things: the [account_mode] member and the other fields of
    [config.json], the authorization log ([authz.jsonl]), and the external store
    that the install record names. A file that is not there and a file that is
    there and cannot be read are different answers. Every read happens on each
    boot, so a base path that was restored to before its bootstrap is noticed
    even when the config no longer asks for [Multi_account] (design 5.1, row 2).

    The log and the store are opened only when their file is there
    ({!Authz_presence}). Opening one ({!Authz_log.open_at_start},
    {!Authz_external_store.open_at_start}) cuts a last line that never ended
    and keeps a lock file next to it; a base path that has neither file gets no
    directory and no lock file. A missing store is absent (design 8.4), and so
    is a store whose directory is missing. A dangling symbolic link on the way
    to either file is not: it makes the file unreadable. A pending intent of the store is judged, not
    settled: {!Authz_high_water.judge} reads a promotion and an abort the same
    way whether their entries were written or not (design 8.2-2, 8.2-3).

    The install record is read on every boot, and a config directory that fails
    its owner test ({!Authz_install_record}) refuses the boot even when no
    record is there: whoever can write that directory could have removed the
    record of a base path that was then restored to before its bootstrap.

    The boot calls {!boot} once, after it holds the BasePath lease and inside an
    Eio event loop, because the zones of the log and the store are
    [Eio.Mutex]es. [config_dir] is {!Env_config_core.masc_config_dir_opt}. *)

(** The [account_mode] member of a [config.json] that parsed as JSON. A value
    that is not an object has no member. A member that appears twice is
    {!Authz_boot_mode.Unknown_value}, whatever the two values are. *)
val requested_of_json : Yojson.Safe.t -> Authz_boot_mode.requested

(** What [config.json] under [base_path] asks for, and its other fields as the
    full decoder reads them. A missing file asks for nothing and has the
    default settings. A file that cannot be read, or is not JSON, asks for
    nothing and has unreadable settings; a warning goes to the log. A JSON
    object gives its member even when the full decoder refuses its other
    fields. *)
val read_config : base_path:string -> Authz_boot_mode.requested * Authz_boot_mode.settings

(* HIGH-RISK-UNREVIEWED: what a command that holds no lease takes for the
   account mode. *)

(** What [config.json] under [base_path] asks a boot to run
    ({!Authz_boot_mode.asked} of {!read_config}): what a command that holds no
    lease reads of the account mode. [Error] for a value the table does not
    know, with the refusal a boot gives for it
    ({!Authz_boot_mode.refusal_to_string}): a command that prepares or opens a
    server stops there, as the boot does. To [Ok Asks_multi_account]
    {!Authz_boot_mode.judge} answers an activation, the account server, an
    uncertainty or a refusal, and never a single user, so a command that
    prepares or opens the server of a single user stops on it too. [Ok] says
    nothing of activation: the log and the store are read under the lease, by
    {!boot}. [Ok Asks_single_user] too for a file that is there and cannot be
    read, or is no JSON object: {!read_config} takes no request from it and
    logs a warning, and a boot judges it as a config that asks for nothing. *)
val asked : base_path:string -> (Authz_boot_mode.asked, Authz_boot_mode.refusal) result

(** The mode that the last mode event of the log made, and the external
    high-water mark. *)
val read_log_and_store
  :  base_path:string
  -> config_dir:string option
  -> Authz_boot_mode.log_mode * Authz_boot_mode.high_water

val input
  :  base_path:string
  -> config_dir:string option
  -> anonymous_mutations:bool
  -> Authz_boot_mode.input

(** Why a boot does not go on. [Multi_account] before activation needs the
    host-local bootstrap, [masc auth bootstrap], which runs while no server runs
    on the base path, so a server has nothing to open there (design 5.1, row 5).
    [Multi_account] with a high-water mark that is absent, does not match or
    cannot be read is [AuthorizationUncertain] (row 8, design 8.2 and 8.4): no
    server serves the records of the accounts while the external store does not
    confirm the log. *)
type stop =
  | Refuse of Authz_boot_mode.refusal * Authz_boot_mode.refusal list
  | Activation_requested
  | Authorization_uncertain

(** What the boot does. *)
type decision =
  | Boot_single_user
  | Boot_after_off of Authz_state.t
      (** The accounts were turned off (row 4). A single user boots, and the
          records of the accounts in the state stay read-only. *)
  | Boot_multi_account
      (** The log made [Multi_account], the external store matches it, and the
          config asks for it with auth on (row 7). The account server boots
          ({!multi_account}); the owner state of a single user does not. *)
  | Stop of stop

val decide : Authz_boot_mode.input -> decision

(** The way from an active workspace to a single user that keeps the records
    of the accounts read-only ({!Authz_off}). One line for the texts of
    [masc auth bootstrap]. *)
val turn_off_line : string

(** What a boot of a base path whose config asks for [Multi_account]
    ({!asked}) does, the
    account server or a stop and never the server of a single user, and the
    two commands that run it. One line, which names the config file, for the
    commands that prepare or open the server of a single user: [masc doctor],
    [masc setup] and the setup journey. *)
val account_installation_line : base_path:string -> string

(** The refusal of {!asked} in the words of the boot
    ({!Authz_boot_mode.refusal_to_string}), and the config file to correct.
    One line, for the commands that hold no lease: [masc doctor],
    [masc setup], [masc setup-server] and the setup journey. *)
val refused_line : base_path:string -> Authz_boot_mode.refusal -> string

(** One line per reason, the first apart, so a stop always has a reason. An
    {!Authorization_uncertain} stop also says what the high-water mark
    found. *)
val messages : Authz_boot_mode.input -> stop -> string * string list

(** A base path that {!boot} judged a single-user boot. Only {!boot} makes one,
    and owner initialization takes one in place of a base path, so a runtime
    that skips the judgment does not compile. *)
type single_user

(** The base path that {!boot} read. *)
val single_user_base_path : single_user -> string

(** The state of the authorization log of a base path whose accounts were
    turned off (row 4). The Keepers, the Runtimes and the account homes it
    names stay read-only: no run starts on them ({!Runtime_account_access}).
    [None] for a base path never set up for accounts. *)
val turned_off : single_user -> Authz_state.t option

(** A base path that {!boot} judged an active multi-account installation
    (row 7). Only {!boot} makes one, and the account server takes one in place
    of a base path, so a server that skips the judgment does not open the
    authorization zone of an installation. No single-user runtime takes one:
    the owner state, the stdio server and a host tool take a {!single_user}. *)
type multi_account

(** The base path that {!boot} read. *)
val multi_account_base_path : multi_account -> string

(** The external store that the install record names and that {!boot} read:
    the store the judgment compared with the log. The account server opens
    its zone over this path and the log of {!multi_account_base_path}. *)
val multi_account_external_store : multi_account -> string

(** The clients that the installation registered at its login providers, as
    [config.json] names them: the [google] and the [github] member, each
    [None] when the file has no such member. A client names the environment
    variable of its secret and holds no secret. *)
type login_clients =
  { google : Masc_domain.login_client option
  ; github : Masc_domain.login_client option
  }

(** The login clients of the [config.json] that {!boot} judged. They come
    from the bytes the judgment read: the file is not read a second time, so
    a server does not judge one config and log persons in with another. A
    multi-account boot stops on a config the full decoder refuses, so these
    are the clients of a config that decoded. *)
val multi_account_login_clients : multi_account -> login_clients

(** What a boot runs on a base path. *)
type booted =
  | Single_user of single_user
  | Multi_account of multi_account

(** {!input}, {!decide} and {!messages} in one call, over one read of the
    files: what the boot runs, and the messages of the stop otherwise. *)
val boot
  :  base_path:string
  -> config_dir:string option
  -> anonymous_mutations:bool
  -> (booted, string * string list) result

(** A base path that a host tool may run turns on as its single user, judged
    without opening a file (plan D2-2). A tool runs while a server may be
    writing the authorization log, and opening the log cuts a last line that
    never ended ({!Authz_log.open_at_start}), so a tool opens neither the log
    nor the external store. A base path that has the log, or an install record
    that names it, is refused whatever its mode: from presence alone a tool
    does not tell a log turned back to [Off] from one in use. A config
    directory that fails its owner test is refused too, as by {!boot}.
    Otherwise [config.json] is judged by {!Authz_boot_mode.judge} with no mode
    event and no store, so the tool runs a single user unless the config asks
    for [Multi_account] or a mode it does not know. *)
val tool
  :  base_path:string
  -> config_dir:string option
  -> (single_user, string * string list) result
