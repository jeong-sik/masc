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
val publish : workspace:string -> integration_id:string -> cli_path:string ->
  t -> (Runtime_setup_accounts.reference, string) result
(** Publish only after successful [observe]. Native references retain the exact
    selected account path. Antigravity publishes a new durable credential copy;
    reauthentication never rewrites the previously selected account reference. *)
