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

    Opening the log and the store cuts a last line that never ended, as
    {!Authz_log.open_at_start} and {!Authz_external_store.open_at_start} do.
    Nothing else is written. A pending intent of the store is judged, not
    settled: {!Authz_high_water.judge} reads a promotion and an abort the same
    way whether their entries were written or not (design 8.2-2, 8.2-3).

    The boot calls {!input} once, after it holds the BasePath lease and inside
    an Eio event loop, because the zones of the log and the store are
    [Eio.Mutex]es. *)

(** The [masc] directory of the config home of the user, as
    {!Authz_install_record.locate} takes it. [XDG_CONFIG_HOME] counts only when
    it is an absolute path; otherwise [HOME/.config], as the XDG Base Directory
    Specification asks. [None] when neither gives one. *)
val config_dir : xdg_config_home:string option -> home:string option -> string option

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

(** What the boot does. Only a single user boots. [Multi_account] before
    activation needs the host-local bootstrap, which this server does not have
    yet. [Multi_account] after activation needs the account layers that serve
    it; booting it without them would serve multi-owned records with the
    behavior of a single user. *)
type decision =
  | Boot_single_user
  | Refuse of Authz_boot_mode.refusal * Authz_boot_mode.refusal list
  | Multi_account_not_activatable
  | Multi_account_not_served of Authz_boot_mode.mode

val decide : Authz_boot_mode.input -> decision

(** One line per reason, for a refusal; none for {!Boot_single_user}. A
    refusal over an external store that could not be read also says why it
    could not be read, since the reasons of the table name only the column. *)
val messages : Authz_boot_mode.input -> decision -> string list
