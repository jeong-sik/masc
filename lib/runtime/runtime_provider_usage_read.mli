(** Asking a provider for its own usage windows without a model turn.

    [Runtime_provider_usage_window] hears a provider's windows only while a
    turn runs. An account the router stopped picking because it is spent runs
    no turn, so the operator never learns when it resets. This module asks
    the provider directly and records the answer in the same table, for the
    operator projection. Routing and admission do not read that table; the
    one read the walk order sees is the read after a 403
    ({!read_after_account_refusal}), which rests a spent account on
    {!Runtime_quota_window}.

    Codex answers [account/rateLimits/read] after account admission, with no
    thread or turn. A provider that declares [usage-read] in runtime.toml is
    asked with one HTTP GET to that URL, authenticated with the key its HTTP
    runtime was built with, and the answer is decoded by the declared shape.
    runtime.toml refuses [usage-read] on an official-client protocol. *)

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
  | Http of http_read

type readable =
  { scope : Runtime_quota_window.scope
  ; how : how
  }

val read_scopes :
  codex:(scope:Runtime_quota_window.scope ->
         Runtime_execution.codex_app_server ->
         (unit, string) result) ->
  fetch:(api_key:Llm_provider.Secret.t -> string -> (string, http_error) result) ->
  readable list ->
  unit
(** Read each scope in order with [codex] or [fetch] (one GET of the
    declared URL), decode, and record.  A failed or raising read is logged
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

(** What the usage endpoint said after the provider refused the account with
    HTTP 403. *)
type account_refusal_read =
  | Spent_until of float
      (** A window's used count reached its limit; the latest stated reset
          among the spent windows, Unix epoch seconds. *)
  | Spent_without_reset  (** A spent window states no reset. *)
  | No_window_spent
      (** Every window has headroom: the refusal is not a spent quota (a
          blocked client, a suspended account), and nothing rests. *)

val account_refusal_read_of_report :
  Runtime_provider_usage_window.report -> account_refusal_read
(** A window is spent when its utilization is a whole [Fraction] of at least
    1.0 or a [Percent] of at least 100. *)

val read_after_account_refusal :
  fetch:(api_key:Llm_provider.Secret.t -> string -> (string, http_error) result) ->
  scope:Runtime_quota_window.scope ->
  http_read ->
  (account_refusal_read, http_error) result
(** Read [scope]'s usage once, record the windows as {!read_scopes} does, and
    rest the scope on {!Runtime_quota_window} when a window is spent:
    [Spent_until t] is {!Runtime_quota_window.note_exhausted} until [t],
    [Spent_without_reset] is {!Runtime_quota_window.note_observed_exhausted}.
    This is the only read whose answer the walk order sees; the startup read
    ({!read_all}) stays an operator projection. A failed read rests nothing. *)

val http_read_of_runtime : Runtime.t -> http_read option
(** The runtime's HTTP usage read when its provider declares [usage-read]. *)

val read_runtime_after_account_refusal : Runtime.t -> unit
(** {!read_after_account_refusal} for a runtime whose provider declares
    [usage-read], with one GET on the process's Eio net and clock, in the
    caller's fiber. A runtime without [usage-read] is not read and nothing
    rests. The outcome or failure is logged without the body or the key. *)
