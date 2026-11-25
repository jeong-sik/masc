(** Typed owner of one Runtime turn.

    [Agent_core] means MASC/AGENT_CORE owns the model/tool/checkpoint loop.
    [Codex_app_server] means the official Codex client owns the whole turn;
    [Claude_code] means the same for the official Claude Code client;
    [Antigravity_cli] means the official Antigravity client owns its model and
    built-in tool loop. MASC owns admission, process lifetime, durable session
    identity, and result projection. *)

type codex_app_server =
  { cli_path : string
  ; account_home : Runtime_official_account.codex Runtime_account_access.sealed
  ; model : string option
  ; timeout_s : float
  }

type antigravity_cli =
  { cli_path : string
  ; model : string
  ; agent : string option
  ; effort : Runtime_antigravity.effort option
  ; oauth_source : string
  ; timeout_s : float
  ; add_dirs : string list
        (** Extra absolute [--add-dir] roots beside the keeper base path,
            from the provider's [add-dirs]. *)
  }

type claude_code =
  { cli_path : string
  ; account_home : Runtime_official_account.claude_code Runtime_account_access.sealed
  ; model : string option
  ; timeout_s : float
  }

type acp_client =
  { driver : Runtime_acp_client.driver
  ; cli_path : string
  ; args : string list
  ; strip_env : string list
  ; skills_dirs : string list
  ; model : Runtime_acp_client.model_selection
  ; effort : Llm_provider.Reasoning_effort.t option
  ; mode : string option
  ; contributor_mode : Runtime_acp_client.contributor_mode
  ; oauth_source : string option
  ; timeout_s : float
  ; admission_timeout_s : float
  }

type t =
  | Agent_core of Runtime_account_access.api_sealed
      (** The provider configuration, credential included. A sender takes it
          from {!Runtime_account_access.authorize_api}, and a reader from
          {!Runtime_account_access.api_declaration}. *)
  | Codex_app_server of codex_app_server
  | Antigravity_cli of antigravity_cli
  | Claude_code of claude_code
  | Acp of acp_client

val same_account_selection : t -> t -> bool
(** Compare captured official-client contexts without exposing credentials.
    Other same-kind execution owners retain their existing binding comparison. *)

val is_person_execution : t -> bool
(** Whether this execution owner targets a person's account rather than an
    operator/host account. *)

type checkpoint_owner =
  | Masc_agent_core
  | Official_client

val supports_request_only_context : t -> bool
(** An Agent Core request whose outside context will not become part of a
    retained conversation. Anthropic may checkpoint carriers alongside signed
    thinking. Official clients and provider-side response chains also retain
    context. *)

(** Where a turn's provider spend becomes visible to MASC, which decides who
    writes the cost ledger's raw rows. Separate from [checkpoint_owner]: that
    answers who holds resumable state, this answers who reports usage.

    - [Each_agent_core_response]: AGENT_CORE hands MASC every provider
      response, and [AfterTurn] carries that response's usage.
    - [Client_usage_stream]: the official client reports usage on its own
      stream while the turn runs, before the turn has an outcome. What one
      report covers (one model response, one client turn, the conversation so
      far) is that client's usage scope, not part of this answer. *)
type usage_report =
  | Each_agent_core_response
  | Client_usage_stream

val supports_native_none : t -> bool
(** Whether the execution owner can enforce that all tools are supplied by MASC. *)

val model_id : t -> string option
val label : t -> string
val checkpoint_owner : t -> checkpoint_owner
(** Typed owner of the runtime's resumable execution state. [Masc_agent_core]
    requires an AGENT_CORE checkpoint on every successful turn. [Official_client]
    forbids projecting the client's session state into an AGENT_CORE checkpoint. *)

val usage_report : t -> usage_report

val claude_code_inline_result_bytes : int
val tool_result_inline_ceiling_bytes : t -> int
(** The actual MASC inline tool-result ceiling for this execution lane. *)
