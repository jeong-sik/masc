(** Audience-tagged cwd value for keeper shell tool responses.

    Tool responses sent back to the keeper LLM must surface a cwd
    the LLM can actually [cd] into. For Local-backend keepers this
    is the host abs path; for Docker-backend keepers it is the
    in-container path under {!Keeper_sandbox.container_root}.

    Operator-facing diagnostics ([Log.Keeper.*],
    [.masc/logs/system_log_*.jsonl], dashboard log ring) keep the
    host-side path because operators ssh into the host filesystem.

    Construction is restricted to two named smart constructors so
    that no caller can accidentally produce a [Sandboxed] value
    without also having computed the container counterpart. The
    serializer {!to_yojson_response} never emits the [host_abs]
    side of [Sandboxed] (fail-closed): the host path can leave
    the module only via {!operator_host}, which the caller must
    invoke explicitly.

    Background: PR #11080 removed [sandbox_host_root] and
    [playground_path] from [keeper_status_detail]'s
    [execution_context], but sibling [cwd] fields in
    [keeper_shell_docker] and [keeper_exec_shell] response
    builders still echoed the host abs path. The Docker
    [--workdir] argument was correctly translated via
    [Keeper_shell_docker.docker_private_workspace_cwd], yet the
    same translation was not propagated to the response JSON.
    The LLM then re-emitted [cd /Users/...] on the next turn,
    which fails inside the container. *)

(** {1 Type} *)

type t = private
  | Local of { abs : string }
  | Sandboxed of { host_abs : string; container_abs : string }

(** {1 Smart constructors} *)

(** [local ~host_cwd] is the cwd response for a Local-backend
    keeper. The host abs path is also what the keeper LLM sees,
    because Local keepers run directly against the host
    filesystem. *)
val local : host_cwd:string -> t

(** [docker ~host_cwd ~container_cwd] is the cwd response for a
    Docker-backend keeper.

    [container_cwd] is the in-container path the LLM should see
    in tool responses; [host_cwd] is retained only so operator
    logs can surface the host-side location.

    Callers typically compute [container_cwd] via
    [Keeper_shell_docker.docker_private_workspace_cwd] for the
    docker [--workdir] argument and pass the same value here so
    the response and the actual exec environment stay in sync. *)
val docker : host_cwd:string -> container_cwd:string -> t

(** [of_sandbox ~sandbox ~host_cwd ~container_cwd_for_docker]
    dispatches on [sandbox.backend]:
    - [Local]  → [local ~host_cwd]
    - [Docker] → [docker ~host_cwd ~container_cwd:container_cwd_for_docker]

    [container_cwd_for_docker] is required by the type but
    unused (and never read) when the backend is Local. *)
val of_sandbox :
  sandbox:Keeper_sandbox.t ->
  host_cwd:string ->
  container_cwd_for_docker:string ->
  t

(** {1 Audience-aware accessors} *)

(** Path the keeper LLM should see in tool response JSON.
    [Local {abs}]                        → [abs]
    [Sandboxed {container_abs; _}]       → [container_abs] *)
val keeper_visible : t -> string

(** Path the operator should see in logs / debugging output.
    Always returns the host-side path supplied at construction. *)
val operator_host : t -> string

(** {1 Serialization} *)

(** [to_yojson_response t] returns [`String (keeper_visible t)].
    Use only for LLM-facing JSON tool responses; for operator
    logs use {!operator_host} explicitly so the audience choice
    is visible at the call site. *)
val to_yojson_response : t -> Yojson.Safe.t
