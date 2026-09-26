(** Asking a provider for its own usage windows without a model turn.

    [Runtime_provider_usage_window] hears a provider's windows only while a
    turn runs. An account the router stopped picking because it is spent runs
    no turn, so the operator never learns when it resets. This module asks
    the provider directly and records the answer in the same table, for the
    operator projection only: routing and admission do not read it.

    Codex answers [account/rateLimits/read] after account admission, with no
    thread or turn. The Antigravity CLI answers a print-mode [/usage] in a
    disposable HOME ({!Runtime_antigravity_usage}), at server start only.
    A provider that declares [usage-read] in runtime.toml is
    asked with one HTTP GET to that URL, authenticated with the key its HTTP
    runtime was built with, and the answer is decoded by the declared shape.
    A provider that also declares [usage-read.refresh-s] is asked again that
    many seconds after each read ends. runtime.toml refuses [usage-read] on an
    official-client protocol. *)

val read_timeout_s : float
(** The bound on one read: a Codex account admission and one request, or one
    whole HTTP GET. *)

val read_codex :
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  scope:Runtime_quota_window.scope ->
  Runtime_execution.codex_app_server ->
  (unit, string) result
(** Read one Codex account and record its windows under [scope]. *)

type http_error
(** Why one HTTP read recorded nothing. *)

val http_error_to_string : http_error -> string
(** Names the failure without the response body or the key. *)

type http_read =
  { credential : Llm_provider.Provider_config.credential_source * Llm_provider.Secret.t
    (** The credential source and key of the runtime's materialized HTTP
        execution: the key its quota scope was derived from at load. *)
  ; usage_read : Runtime_schema.usage_read
  }

type how =
  | Codex of Runtime_execution.codex_app_server
  | Antigravity of Runtime_execution.antigravity_cli
  | Http of http_read

type readable =
  { scope : Runtime_quota_window.scope
  ; how : how
  }

val read_scopes :
  codex:(scope:Runtime_quota_window.scope ->
         Runtime_execution.codex_app_server ->
         (unit, string) result) ->
  antigravity:(scope:Runtime_quota_window.scope ->
               Runtime_execution.antigravity_cli ->
               (unit, string) result) ->
  fetch:(api_key:Llm_provider.Secret.t -> string -> (string, http_error) result) ->
  readable list ->
  unit
(** Read each scope in order with [codex], [antigravity] or [fetch] (one GET
    of the declared URL), decode, and record.  A failed or raising read is logged
    with its scope (and shape) and does not stop the scopes after it; only
    {!Eio.Cancel.Cancelled} is re-raised.  A read that states no windows logs
    one info line.  An HTTP read with an empty key fails without a request. *)

val read_all :
  mgr:_ Eio.Process.mgr ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  unit
(** Read every configured account that can answer, once per quota scope. A
    failed read is logged with its scope (and shape for an HTTP read) and
    leaves that scope as it was; neither the response body nor the key is
    logged. *)

val refresh_readables :
  clock:_ Eio.Time.clock ->
  fetch:(api_key:Llm_provider.Secret.t -> string -> (string, http_error) result) ->
  catalogue:(unit -> readable list) ->
  unit
(** Repeat the read of every HTTP account in [catalogue ()] whose provider
    declares [usage-read.refresh-s], each waiting its own period from the
    call. An account whose static key is empty is not repeated: that read
    never reaches a request, and the key stays empty while the runtime lives.
    Before each repeat the account is looked up in [catalogue ()] again. Its
    repeats end when it is gone, no longer declares [refresh-s], or can no
    longer answer; otherwise the period it declares then is the wait after
    that read. A failed or raising read is logged the way {!read_scopes}
    logs it, and the repeats go on; only {!Eio.Cancel.Cancelled} is
    re-raised. Returns when every account's repeats have ended. *)

val refresh_declared :
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  clock:_ Eio.Time.clock ->
  unit
(** {!refresh_readables} over the runtime catalogue, one HTTP GET per read.
    The accounts that repeat are the ones the catalogue declares at the call.
    An account whose repeats a config save ended does not repeat again, even
    when a later save restores it, and one whose [refresh-s] a save adds
    does not start; both repeat from the next server start. The server calls
    it right after {!read_all}, so each first repeat waits its period from
    the end of that whole start pass. *)

type background =
  | Started  (** A read was forked on the server's root switch. *)
  | Already_reading  (** A read for this scope is still running. *)
  | No_root_switch  (** No server root switch is installed (outside a server). *)

val read_codex_in_background :
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  scope:Runtime_quota_window.scope ->
  Runtime_execution.codex_app_server ->
  background
(** {!read_codex} in a fiber on the server's root switch, so it outlives the
    turn that asked for it, with at most one read per scope at a time. Its
    failure is logged. *)
