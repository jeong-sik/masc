val contains_forbidden_shell_chars_coding : string -> bool
val contains_substring : string -> string -> bool
val has_process_substitution : string -> bool
(* [split_pipeline_segments] removed by RFC-0131 Phase 2 (Shell IR
   Promotion Goal, 2026-05-18).  The string-based pipeline splitter is
   superseded by [Shell_command_gate.parse]; no caller remains. *)
val split_shell_tokens : string -> string list
val strip_wrapping_quotes : string -> string
val basename_token : string -> string
val is_env_assignment : string -> bool
val skip_env_assignments : string list -> string option
val command_after_env_prefix : string list -> string option
val opam_exec_command_name : string list -> string option
val segment_command_name : string -> string option
val invokes_direct_dune : string -> bool
val is_digits_only : string -> int -> int -> bool
val is_safe_fd_redirect_token : string -> bool
val has_unsafe_redirection : string -> bool
val extract_command_name : string -> string option
