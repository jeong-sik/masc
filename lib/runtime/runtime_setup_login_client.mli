(** Official-client login adapters. The caller owns and reaps the login process
    before calling [observe]; authentication and invocation are
    separate observations. No operation changes the host process environment. *)
type client = Codex | Claude | Antigravity
type native = Runtime_account_home_layout.client = Codex_home | Claude_home
(** A client that signs in to an account home. *)
type t
(** A login, with the {!browser} that was decided for its sign-in. *)
type observation = Authenticated | Login_completed | Credential_captured

(** What a sign-in child is handed for the browser it would start. *)
type browser

val host_browser : browser
(** No command: the environment of the child carries no [BROWSER], and the
    client does what it does without one. *)

val no_host_browser : ?getenv:(string -> string option) -> unit -> (browser, string) result
(** A command that does nothing, for a sign-in that someone at another machine
    started: they open the link the client prints. The command is the [true]
    utility that an absolute directory of [PATH] holds, and the result is an
    error when [PATH] holds none. [getenv] reads [PATH]; it is the environment
    of this process unless given. {!prepare} takes the answer, so a refusal
    leaves no home behind. *)

val browser_command : browser -> string option
(** The command a child is handed in place of the browser of this machine, and
    [None] for {!host_browser}. *)

val prepare : browser:browser -> runtime_root:string -> account_id:string ->
  client:client -> existing:Runtime_setup_accounts.binding option -> (t, string) result
(** The login of a sign-in whose browser is [browser]. For an account that is
    not there yet it makes the home the login runs in. *)
val selected_native : browser:browser -> native -> account_home:string -> (t, string) result
(** A login on an account home the operator already declared, as the
    installer's sign-in has it: the exact spelling, which must name an owned
    directory. *)
val account_home : runtime_root:string -> account_id:string -> client:client ->
  (string, string) result
(** The home that {!prepare} made for a new account [account_id] of [client]
    under [runtime_root]. It must still be there, an owned, protected
    directory. Antigravity keeps no such home. *)
val account_home_path : runtime_root:string -> account_id:string -> client:client ->
  (string, string) result
(** Where {!account_home} looks: the home of [account_id] of [client] under
    [runtime_root], as the layout spells it. It reads the real path of the
    runtime root, looks at no home and makes nothing. *)
val home_dir : t -> string
val argv : cli_path:string -> t -> string list
val environment : t -> (string array, string) result
(** The environment of the login child. A command of the login's browser is
    bound once, as [BROWSER]. Claude Code hands the browser of the machine a
    link whose approval returns to a port of that machine, so an approval
    there signs the approver's account in to the home of the login. *)
val is_pty : t -> bool
val saved_login_check : t -> (unit -> (bool, string) result) option
(** Antigravity runs its full interactive client, so its newly saved login
    ends the login process before it accepts a conversation. Other clients
    have a login command whose exit owns completion and return [None].
    This check only reads; a changing or not-yet-parseable credential waits
    for the writer. [observe] captures the login after process cleanup. *)
val observe : mgr:_ Eio.Process.mgr -> clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t -> cli_path:string ->
  account_request:Runtime_account_access.request -> t -> (observation, string) result
(** Claude/Codex query native authentication, on the home only when
    {!Runtime_account_access.authorize} allows [account_request] there. Muse
    validates the captured native auth document; Antigravity captures its
    selected keychain/file credential. The latter two are not network
    authentication or model invocation proof, and start no CLI. *)
val publish : workspace:string -> integration_id:string -> cli_path:string ->
  t -> (Runtime_setup_accounts.reference, string) result
(** Native references may be published before login for recovery; they prove
    only account selection. Antigravity publication requires captured credentials.
    Native references retain the exact
    selected account path. Antigravity publishes a new durable credential copy;
    reauthentication never rewrites the previously selected account reference. *)
