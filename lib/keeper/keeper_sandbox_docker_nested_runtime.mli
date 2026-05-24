(** Nested-container runtime detection for keeper_bash sandboxing.

    Statically detects whether a shell command would spawn a nested
    Docker/Podman/nerdctl/buildah runtime (or touch a container daemon
    socket) when the sandbox profile forbids escape. *)

val nested_container_runtime_tokens : string list
val sandbox_socket_markers : string list

type shell_guard_token =
  | Guard_word of string * bool
  | Guard_separator

val shell_guard_tokens : string -> shell_guard_token list

val shell_assignment_like : string -> bool
val env_option_takes_arg : string -> bool
val env_option_like : string -> bool
val env_split_string_inline_value : string -> string option

val shell_interpreter_names : string list
val is_shell_interpreter : string -> bool
val word_contains_runtime_token : string -> string -> bool
val shell_c_payload : shell_guard_token list -> string option
val command_word_mentions_nested_runtime : shell_guard_token list -> bool
val command_substitution_mentions_nested_runtime : shell_guard_token list -> bool
val unquoted_word_mentions_socket_marker : shell_guard_token list -> bool

val command_uses_nested_container_runtime : string -> bool
