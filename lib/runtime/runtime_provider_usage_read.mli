(** Asking a provider for its own usage windows without a model turn.

    Turn events alone cannot report the windows of an account that the router
    stopped picking. Codex, HTTP and Antigravity reads record provider reports
    in [Runtime_provider_usage_window] for the operator projection. Routing
    and admission do not read that observation table. An HTTP account read
    after a 403 ({!read_after_account_refusal}) can also rest a
    spent scope on {!Runtime_quota_window}. A Muse [usage/read] after a model error records
    only provider-stated exhaustion there, not a usage-window report.

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
(** The bound on one read: a Codex account admission and one request, one
    whole HTTP GET, or a Muse [usage/read]. *)

val read_codex :
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  scope:Runtime_quota_window.scope ->
  Runtime_execution.codex_app_server ->
  (unit, string) result
(** Read one Codex account and record its windows under [scope]. The answer
    rests nothing: this is the start read ({!read_all}). *)

val read_muse :
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  scope:Runtime_quota_window.scope ->
  Runtime_muse_serve.config ->
  (unit, string) result
(** Read [usage/read] without a model turn. Only a provider-stated exhausted
    window with a future reset rests [scope]; an absent or unspent report
    changes no routing state. *)

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
  | Scheduling_failed  (** The root owner could not schedule the read. *)

val read_codex_after_spent_usage_refusal :
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  scope:Runtime_quota_window.scope ->
  Runtime_execution.codex_app_server ->
  background
(** Refresh the operator projection after a spent-usage refusal. Neither the
    refusal nor this account-wide read attributes a metered limit_id to the
    rejected call. Preserve the turn's existing observation, including when
    only one bucket is reported; no reset is inferred. Runs on the server's
    root switch, with at most one read per scope. Read failures are logged. *)

val read_muse_in_background :
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  scope:Runtime_quota_window.scope ->
  Runtime_muse_serve.config ->
  background
(** {!read_muse} after a Muse model-error terminal. The read outlives the
    failed turn and never resubmits its input. At most one read per account
    scope is active. *)

module For_testing : sig
  val start_background :
    scope:Runtime_quota_window.scope ->
    fork:((unit -> unit) -> unit) ->
    read:(unit -> unit) ->
    background
  (** Exercise the claim and fork boundary without a running server. *)
end

(** What a usage read said after the provider refused the account: an HTTP
    403 ({!read_after_account_refusal}). Only windows whose role is
    {!Runtime_provider_usage_window.Gates_model_calls} count. *)
type account_refusal_read =
  | Spent_until of float
      (** The spent gating windows all belong to one limit; the latest
          stated reset among them, Unix epoch seconds. *)
  | Spent_without_reset  (** A spent gating window states no reset. *)
  | Spent_in_several_limits of string option list
      (** Spent gating windows belong to more than one limit (their limit
          ids, sorted; [None] for a window that names none). A refusal does
          not name the limit that refused it, so no reset is the rest: the
          scope keeps the refusal's observation, as [Spent_without_reset]. *)
  | No_window_spent
      (** Every gating window has headroom, and the read rests nothing.
          After a 403 the refusal is not a spent quota (a blocked client, a
          suspended account). *)

val account_refusal_read_of_report :
  Runtime_provider_usage_window.report -> account_refusal_read
(** A window is spent when its utilization is a [Fraction] of at least 1.0
    or a [Percent] of at least 100. Windows that count other use (Z.AI's
    TIME_LIMIT, OpenRouter's free-model requests) and unclassified ones are
    ignored. *)

val read_after_account_refusal :
  fetch:(api_key:Llm_provider.Secret.t -> string -> (string, http_error) result) ->
  scope:Runtime_quota_window.scope ->
  http_read ->
  (account_refusal_read, http_error) result
(** Read [scope]'s usage once with the credential as materialized (a
    refreshable credential is not refreshed: the read fails instead), record
    the windows as {!read_scopes} does, and rest the scope on
    {!Runtime_quota_window} when a gating window is spent: [Spent_until t]
    is {!Runtime_quota_window.note_exhausted} until [t],
    [Spent_without_reset] is {!Runtime_quota_window.note_observed_exhausted}.
    A [t] not after the answer's arrival names no rest and is returned and
    recorded as [Spent_without_reset].
    This read affects the walk order; the startup read ({!read_all}) stays an operator
    projection. A failed read rests nothing. *)

val http_read_of_runtime : Runtime_instance.t -> http_read option
(** The runtime's HTTP usage read when its provider declares [usage-read]. *)

type account_refusal_skip =
  | No_usage_read  (** The provider declares no [usage-read]. *)
  | Scope_already_resting
      (** The scope already has a live quota mark, e.g. from a sibling's
          read in the same walk. *)
  | Already_reading  (** A read for this scope is running. *)
  | No_net_or_clock  (** No Eio net or clock is installed. *)

type account_refusal_outcome =
  | Read of account_refusal_read
  | Read_failed of http_error
  | Read_raised of string  (** The exception's constructor name only. *)
  | Skipped of account_refusal_skip

val read_runtime_after_account_refusal :
  ?fetch:(api_key:Llm_provider.Secret.t -> string -> (string, http_error) result) ->
  Runtime_instance.t ->
  account_refusal_outcome
(** {!read_after_account_refusal} for [rt]'s materialized scope, in the
    caller's fiber, at most one per scope at a time (shared with
    {!read_codex_after_spent_usage_refusal}). [fetch] defaults to one GET on the
    process's Eio net and clock. The outcome is logged without the body or
    the key, and returned. *)
