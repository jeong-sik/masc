(** Typed owner of one Runtime turn.

    [Agent_core] means MASC/AGENT_CORE owns the model/tool/checkpoint loop.
    [Codex_app_server] means the official Codex client owns the whole turn;
    [Claude_code] means the same for the official Claude Code client;
    [Antigravity_cli] means the official Antigravity client owns its model and
    built-in tool loop; and [Muse_serve] means the same for Muse Code, driven
    over [muse serve]. MASC owns admission, process lifetime, durable session
    identity, and result projection. *)

type codex_app_server =
  { cli_path : string
  ; account_home : string option
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
  ; account_home : string option
  ; model : string option
  ; timeout_s : float
  }

type muse_serve =
  { cli_path : string
  ; account_home : string
    (** Explicit, validated account directory; no ambient account selection. *)
  ; model : string
        (** The binding's [api-name], sent as [session/start]'s [modelId]. *)
  ; timeout_s : float
        (** Bounds admission, and the silence between protocol messages
            unless the model declares [turn-timeout-s]. *)
  }

type t =
  | Agent_core of Llm_provider.Provider_config.t
  | Codex_app_server of codex_app_server
  | Antigravity_cli of antigravity_cli
  | Claude_code of claude_code
  | Muse_serve of muse_serve

type checkpoint_owner =
  | Masc_agent_core
  | Official_client

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
