(** Official-client login adapters. The caller owns the login process and calls
    [observe] only after its successful exit; authentication and invocation are
    separate observations. No operation changes the host process environment. *)
type client = Codex | Claude | Antigravity | Muse
type t
type observation = Authenticated | Login_completed | Credential_captured

val prepare : runtime_root:string -> account_id:string -> client:client ->
  existing:Runtime_setup_accounts.binding option -> (t, string) result
val selected_native : Runtime_account_email.native_client -> account_home:string ->
  (t, string) result
(** A login on an account home the operator already declared, as the
    installer's sign-in has it: the exact spelling, which must name an owned
    directory. *)
val native_email_account : t -> Runtime_account_email.account option
(** The account a Codex, Claude Code or Muse Code login's record is kept
    under: its client kind and home, spelled as selected. [None] for
    Antigravity, whose record follows the credential file a completed login
    publishes. *)
val home_dir : t -> string
val argv : cli_path:string -> t -> string list
val is_pty : t -> bool

type started
(** A login whose account record setup has already marked as started. Only
    {!start} makes one, and the child's environment needs it, so no official
    client runs on an account before setup has marked it. *)

val start : t -> started
(** Before a native client may rewrite its home's login files, record
    [Login_unfinished] for that account, replacing any earlier email. The
    email is display data, so this never fails the login: if the record cannot
    be written, the failure is logged and the earlier record is removed; if
    that fails as well, it is logged, and a record directory
    {!Runtime_setup_accounts.set_email} refuses reads as unreadable, not as the
    earlier email. Antigravity signs in on a fresh copy and publishes a new
    credential file, so nothing is recorded before it runs. *)

val login_of : started -> t
val environment : started -> (string array, string) result

val finish :
  save_complete:(unit -> (unit, 'error) result) ->
  account:(unit -> (Runtime_account_email.account, string) result) ->
  started -> (unit, 'error) result
(** For a login whose client exited successfully: [save_complete] first (the
    server saves its Complete receipt there), and only when it succeeds,
    inside [Eio.Cancel.protect], record [Completed] with the email
    {!account_email} reads, or why it read none, under [account ()]. Returns
    [save_complete]'s error unchanged. A record that cannot be written is
    logged and never an error; the account then keeps the [Login_unfinished]
    that {!start} wrote. *)
val observe : mgr:_ Eio.Process.mgr -> clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t -> cli_path:string -> t -> (observation, string) result
(** Claude/Codex query native authentication. Muse validates the captured native
    auth document; Antigravity captures its selected keychain/file credential.
    The latter two are not network authentication or model invocation proof. *)
val account_email : t -> (Runtime_account_email.t, Runtime_account_email.missing) result
(** The email the client wrote into its own login files for this account. Read
    it after the client's login has exited successfully; it is display text for
    setup surfaces and makes no authentication claim. See
    {!Runtime_account_email} for each source. *)
val email_account : workspace:string -> integration_id:string -> cli_path:string ->
  t -> Runtime_setup_accounts.reference -> (Runtime_account_email.account, string) result
(** The account setup keeps this login's email record under, with this login's
    client kind: a native login's own home, which is the exact path
    {!publish} registers, or the Antigravity credential file the reference
    selects. *)
val publish : workspace:string -> integration_id:string -> cli_path:string ->
  t -> (Runtime_setup_accounts.reference, string) result
(** Native references may be published before login for recovery; they prove
    only account selection. Antigravity publication requires captured credentials.
    Native references retain the exact
    selected account path. Antigravity publishes a new durable credential copy;
    reauthentication never rewrites the previously selected account reference. *)
