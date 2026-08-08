(** Typed owner of one Runtime turn.

    [Agent_core] means MASC/OAS owns the model/tool/checkpoint loop.
    [Codex_app_server] means the official Codex client owns the whole turn;
    MASC owns admission, process lifetime, and result projection.
    [Antigravity_cli] has the same official-client ownership boundary, with
    Antigravity's built-in tool loop fixed to plan+sandbox execution. *)

type codex_app_server =
  { cli_path : string
  ; model : string option
  ; timeout_s : float
  }

type antigravity_cli =
  { cli_path : string
  ; model : string option
  ; timeout_s : float
  }

type t =
  | Agent_core of Llm_provider.Provider_config.t
  | Codex_app_server of codex_app_server
  | Antigravity_cli of antigravity_cli

type checkpoint_owner =
  | Masc_oas
  | Official_client

val agent_core_provider_config : t -> Llm_provider.Provider_config.t option
val model_id : t -> string option
val label : t -> string
val checkpoint_owner : t -> checkpoint_owner
(** Typed owner of the runtime's resumable execution state. [Masc_oas]
    requires an OAS checkpoint on every successful turn. [Official_client]
    forbids projecting the client's session state into an OAS checkpoint. *)
