(** Lodge Daemon - Unified Agent Coordinator *)

type mood = Satisfied | Curious | Skeptical | Neutral | Excited
type config = { enabled: bool; check_interval_s: float }
let default_config = { enabled = false; check_interval_s = 60.0 }
let init ~config = if config.enabled then print_endline "Lodge Daemon init"
