(** Typed owner of one Runtime turn.

    [Agent_core] means MASC/AGENT_CORE owns the model/tool/checkpoint loop.
    [Codex_app_server] means the official Codex client owns the whole turn;
    [Claude_code] means the same for the official Claude Code client; and
    [Antigravity_cli] means the official Antigravity client owns its model and
    built-in tool loop. MASC owns admission, process lifetime, durable session
    identity, and result projection. *)

type codex_app_server =
  { cli_path : string
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
  ; model : string option
  ; timeout_s : float
  }

type t =
  | Agent_core of Llm_provider.Provider_config.t
  | Codex_app_server of codex_app_server
  | Antigravity_cli of antigravity_cli
  | Claude_code of claude_code

type checkpoint_owner =
  | Masc_agent_core
  | Official_client

val model_id : t -> string option
val label : t -> string
val checkpoint_owner : t -> checkpoint_owner
(** Typed owner of the runtime's resumable execution state. [Masc_agent_core]
    requires an AGENT_CORE checkpoint on every successful turn. [Official_client]
    forbids projecting the client's session state into an AGENT_CORE checkpoint. *)
