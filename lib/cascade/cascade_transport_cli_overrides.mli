(** CLI-transport override record extracted from [Cascade_transport]. *)

type cli_transport_overrides =
  { cwd : string option
  ; claude_mcp_config : string option
  ; claude_allowed_tools : string list option
  ; claude_permission_mode : string option
  ; claude_max_turns : int option
  ; gemini_yolo : bool option
  ; cli_subprocess_idle_sec : float option
  }
(** Per-call overrides forwarded to CLI transports. *)

val default_cli_transport_overrides : cli_transport_overrides
(** No-overrides default used when a transport receives no explicit override. *)
