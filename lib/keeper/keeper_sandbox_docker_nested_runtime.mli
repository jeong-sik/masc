(** Nested-container runtime detection for keeper_bash sandboxing.

    Statically detects whether a shell command would spawn a nested
    Docker/Podman/nerdctl/buildah runtime (or touch a container daemon
    socket) when the sandbox profile forbids escape. *)

val nested_container_runtime_tokens : string list
val sandbox_socket_markers : string list

val command_uses_nested_container_runtime : string -> bool
