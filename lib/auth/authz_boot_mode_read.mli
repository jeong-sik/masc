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
    [Multi_account] after activation needs the account layers that serve it;
    booting it without them would serve multi-owned records with the behavior
    of a single user. The lines say "this build", because [masc auth bootstrap]
    prints them too. *)
type stop =
  | Refuse of Authz_boot_mode.refusal * Authz_boot_mode.refusal list
  | Activation_requested
  | Multi_account_not_served of Authz_boot_mode.mode

(** What the boot does. Only a single user boots. *)
type decision =
  | Boot_single_user
  | Boot_after_off of Authz_state.t
      (** The accounts were turned off (row 4). A single user boots, and the
          records of the accounts in the state stay read-only. *)
  | Stop of stop

val decide : Authz_boot_mode.input -> decision

(** How a workspace goes back to a single user while this build does not
    serve multi-account. Without the log, the external store and the install
    record, and with no [account_mode] in [config.json], the boot cannot tell
    the base path from one never activated, and boots a single user (row 1).
    It is one line for {!messages} and for the texts of [masc auth bootstrap]. *)
val single_user_again : string

(** The way from an active workspace to a single user that keeps the records
    of the accounts read-only ({!Authz_off}). One line for {!messages} and for
    the texts of [masc auth bootstrap]. *)
val turn_off_line : string

(** One line per reason, the first apart, so a stop always has a reason. A
    {!Multi_account_not_served} stop also says what the high-water mark found
    when it is not a match, and for an active workspace (row 7) it says
    {!turn_off_line}. {!Activation_requested} and {!Multi_account_not_served}
    end with {!single_user_again}. *)
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

(** {!input}, {!decide} and {!messages} in one call: the judged base path for a
    single-user boot, and the messages of the stop otherwise. *)
val boot
  :  base_path:string
  -> config_dir:string option
  -> anonymous_mutations:bool
  -> (single_user, string * string list) result

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
