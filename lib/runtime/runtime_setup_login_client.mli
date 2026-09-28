(** Official-client login adapters. The caller owns the login process and calls
    [observe] only after its successful exit; authentication and invocation are
    separate observations. No operation changes the host process environment. *)
type client = Codex | Claude | Antigravity | Muse
type t
type observation = Authenticated | Login_completed | Credential_captured

val prepare : runtime_root:string -> account_id:string -> client:client ->
  existing:Runtime_setup_accounts.binding option -> (t, string) result
val home_dir : t -> string
val argv : cli_path:string -> t -> string list
val environment : t -> (string array, string) result
val is_pty : t -> bool
val observe : mgr:_ Eio.Process.mgr -> clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t -> cli_path:string -> t -> (observation, string) result
(** Claude/Codex query native authentication. Muse validates the captured native
    auth document; Antigravity captures its selected keychain/file credential.
    The latter two are not network authentication or model invocation proof. *)
val account_email : t -> (Runtime_account_email.t, Runtime_account_email.missing) result
(** The email the client wrote into its own login files for this account. Call
    after [observe] succeeds; it is display text for setup surfaces and makes
    no authentication claim. See {!Runtime_account_email} for each source. *)
val email_account : workspace:string -> integration_id:string -> cli_path:string ->
  t -> Runtime_setup_accounts.reference -> (Runtime_account_email.account, string) result
(** The account setup keeps this login's email record under: the reference's
    account path, spelled exactly as runtime.toml records it for a provider
    saved from that reference, with this login's client kind. *)
val start_email_record : workspace:string -> integration_id:string -> cli_path:string ->
  t -> Runtime_setup_accounts.reference -> (unit, string) result
(** Before a native client may rewrite its home's login files, record that a
    login has started there, replacing any earlier email. Antigravity signs in
    on a fresh copy, so its selected file keeps its record. *)
val finish_email_record : workspace:string -> integration_id:string -> cli_path:string ->
  t -> Runtime_setup_accounts.reference -> (Runtime_account_email.record, string) result
(** After a completed login, record the email {!account_email} reads, or why it
    read none, and return what was written. *)
val publish : workspace:string -> integration_id:string -> cli_path:string ->
  t -> (Runtime_setup_accounts.reference, string) result
(** Native references may be published before login for recovery; they prove
    only account selection. Antigravity publication requires captured credentials.
    Native references retain the exact
    selected account path. Antigravity publishes a new durable credential copy;
    reauthentication never rewrites the previously selected account reference. *)
