(** Runtime_vibe_acp_readiness — whether Vibe can take a lane call, read over
    [vibe-acp] without a prompt.

    RFC-vibe-official-client-lane §2.2 and §4.2. [vibe-acp] speaks the Agent
    Client Protocol (JSON-RPC, one message per line on stdio). This module
    sends [initialize], the Vibe extension [_auth/status], [session/new] and
    the extension [_account/read], then closes stdin. No prompt is sent, so no
    model is called. The two extensions are in the Vibe 3.1.0 source
    ([vibe/acp/agent.py]) and not in Vibe's public documentation; the
    shapes below were measured against 3.1.0, and this module does not
    check the version [vibe-acp] reports.

    The child gets {!Runtime_vibe_cli.child_environment}: Vibe reads its key
    from the process environment first, so the check must see the same
    credential a lane call would use.

    Every wire enum decodes to a closed variant with one [Unrecognized_*] arm
    that keeps the value. *)

(** [_auth/status] [authState], from Vibe's [AuthStateKind]. It says where a
    stored credential came from; Vibe does not ask the server for it, so an
    expired or revoked key still reads [Os_keyring]. [Signed_out] means no
    stored value at all. *)
type auth_state =
  | Signed_out
  | Auth_not_required
  | Os_keyring
  | Vibe_home_env_file  (** A key in [~/.vibe/.env]; it wins over the keyring. *)
  | Process_env
  | Unsupported_provider
  | Unrecognized_auth_state of string

type auth_status =
  { authenticated : bool
  ; auth_state : auth_state
  }

(** [_account/read] [status], from Vibe's [AccountStatus]. *)
type account_status =
  | Ready
  | Missing_key
  | Unauthorized  (** [/whoami] answered 401 or 403: an expired or revoked key. *)
  | Unavailable
      (** No account read: the active provider is not Mistral, or the account
          service did not answer. *)
  | Unrecognized_account_status of string

(** [plan.kind], from Vibe's [AccountPlanKind]. *)
type plan_kind =
  | Api
  | Chat
  | Mistral_code
  | Unrecognized_plan_kind of string

(** [apiKey.scope]. Vibe derives the plan kind from it: [workspace] for [api],
    [vibe] for [chat], [codestral] for [mistral_code]. *)
type key_scope =
  | Workspace
  | Vibe
  | Codestral
  | Unrecognized_key_scope of string

(** The monthly Vibe Code allowance ([/v1/billing/budget]'s [vibe_budget]). *)
type budget =
  { usage_percentage : float  (** Percent of the allowance used. *)
  ; reset_at : string option
  ; payg_enabled : bool
  }

type account =
  { status : account_status
  ; plan_kind : plan_kind option  (** [None]: Vibe sent no [plan]. *)
  ; key_scope : key_scope option  (** [None]: Vibe sent no [apiKey]. *)
  ; budget : budget option
        (** [None]: Vibe gave no budget. In Vibe 3.1.0 ([_account.py]
            [_budget_view], [_settled]) that is billing not answering within
            Vibe's own 2-second grace, a refused billing read, an allowance
            of 0, or a provider that is not Mistral. So an allowance already
            used up can arrive as [None] when billing is slow. *)
  }

type readiness =
  | Not_signed_in of auth_state
      (** [_auth/status] said [authenticated=false]. No session was opened
          and no account was read: Vibe refuses [session/new] without a
          credential. *)
  | Signed_in of
      { auth_state : auth_state
      ; account : account
      }

type not_ready =
  | Not_authenticated of auth_state
  | Credential_not_keyring of auth_state
      (** Signed in, but the credential state is not [os_keyring]: a key in
          [~/.vibe/.env] or the process environment, a provider that needs
          no key, or one Vibe does not support. *)
  | Account_not_ready of account_status
  | Key_not_vibe_scope of key_scope option
  | Budget_used_up of budget
      (** At least 100% of the allowance used. With pay-as-you-go on, Vibe's
          comment on the field says further usage is billed instead of
          paused; with it off, calls stop. The lane takes neither. *)

type budget_knowledge =
  | Known of budget
  | Unknown  (** Vibe gave no budget (see {!account.budget}). *)

val verdict : readiness -> (budget_knowledge, not_ready list) result
(** [Ok] when the credential is the keyring one, the account is [ready], the
    key has scope [vibe], and a known budget is below 100% (a budget that
    does not compare below 100, NaN included, is used up). The [Ok] value
    says whether the budget was known: this function does not refuse an
    unknown budget and does not report it as room; the caller decides.
    Otherwise every reason that applies, in that order. *)

val not_ready_to_string : not_ready -> string

type error =
  | Workdir_not_absolute of string
  | Invalid_timeout of float  (** Not finite or not above zero. *)
  | Spawn_failed of string
      (** Eio could not start [cli_path]: not found, not executable, a pipe
          or fork failure, or a child setup step that failed. *)
  | Timed_out of { after_s : float }
  | Rpc_error of
      { meth : string
      ; code : int option  (** [None] when the error carries no integer code. *)
      ; message : string  (** Vibe's text, redacted. *)
      }
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Process_exited of { stderr_tail : string }
      (** stdout closed, or stdin refused a write, before every answer
          arrived. The tail is read after the child was reaped. *)

val error_to_string : error -> string

val decode_auth_status : Yojson.Safe.t -> (auth_status, error) result
val decode_account : Yojson.Safe.t -> (account, error) result

val read
  :  host:Runtime_account_access.host_account
       (** The start the access allows: Vibe reads the configuration of the
           host user (multi-account plan D3b). *)
  -> mgr:_ Eio.Process.mgr
  -> clock:_ Eio.Time.clock
  -> fs:Eio.Fs.dir_ty Eio.Path.t
  -> workdir:string
  -> cli_path:string
  -> timeout_s:float
  -> unit
  -> (readiness, error) result
(** Spawn [cli_path] (the [vibe-acp] binary) in the absolute [workdir], ask,
    and stop it. [timeout_s] bounds the exchange; past it the child is
    killed at once. When the exchange ends in time, stdin is closed and a
    child that does not exit within 5 s is killed. Cancelling the calling
    fiber kills and reaps the child (Eio's switch).

    The check is not read-only for Vibe: a successful [_account/read]
    rewrites Vibe's whoami cache under [~/.vibe] and can update its tenant
    URLs in [config.toml]; [session/new] takes a session lease and leaves a
    directory under [~/.vibe/logs/session/plugins/data/]. The account read
    follows Vibe's active provider, so the check must run with the config a
    lane call uses. *)
