(** CLI transport override record shared by cascade CLI providers. *)

type cli_transport_overrides =
  { cwd : string option
  ; claude_mcp_config : string option
  ; claude_allowed_tools : string list option
  ; claude_permission_mode : string option
  ; claude_max_turns : int option
  ; gemini_yolo : bool option
  ; cli_subprocess_idle_sec : float option
  }

val default_cli_transport_overrides : cli_transport_overrides
(** No-op override record used when callers do not supply CLI overrides. *)
