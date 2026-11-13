(** The guest agent of an Apple microVM keeper, seen from its boot (RFC
    microvm-guest-agent-over-socket 3.2, 3.6): where its socket is on both
    sides, the boot plan that starts it, and the host path made ready just
    before that boot. *)

val guest_path : string
(** Where the agent binds inside the guest. It is on the root filesystem:
    [--publish-socket] does not reach a socket on a tmpfs, a named volume or
    a host directory mount (RFC 4.2). The guest's vminitd connects to it under
    [/run/container/<guest name>/rootfs], and that whole path fits Linux's
    107-byte socket path for the longest guest name. *)

val host_path : base_path:string -> guest_name:string -> string
(** [<base_path>/.masc/microvm/agent/<16 hex of SHA-256(guest_name)>.sock].
    A function of the base path and the guest name alone, so a server that
    attaches to a running guest names the same socket the boot published. The
    name is hashed: a 63-character guest name under [/Users/<user>/me] is
    already past macOS's 103-byte socket path. A base path long enough to
    push even this past the limit is refused by
    {!Keeper_microvm_boot_plan.validate}. *)

val relay_label : string * string
(** The stable plan label naming the relay version the agent speaks
    ({!Exec_ssh_protocol.Relay.version}). It is part of the plan digest, so a
    server speaking another version replaces the guest instead of adopting
    an agent it would refuse. *)

val plan :
  uid:int ->
  gid:int ->
  host_socket:string ->
  image:string ->
  guest_size:Keeper_microvm_guest_size.t ->
  mounts:Keeper_microvm_boot_plan.guest_mount list ->
  network:Keeper_microvm_boot_plan.network ->
  environment:(string * string) list ->
  labels:(string * string) list ->
  Keeper_microvm_boot_plan.t
(** The plan every Apple Keeper guest boots with (RFC 0, 3.2). The first
    process is [masc-exec-shim --serve] started as [0:0]; it binds
    {!guest_path}, re-mounts the root read-only and drops to [uid:gid]. So
    the plan holds every {!Keeper_microvm_backend.all_guest_constraints} but
    [Read_only_rootfs], gives back [CAP_SETUID], [CAP_SETGID] and
    [CAP_SYS_ADMIN] after dropping all, and publishes the socket at
    [host_socket]. The agent hands its own environment and working directory
    ({!Keeper_sandbox_microvm.work_volume_guest_root}) to every request, so
    {!Keeper_sandbox_microvm.request_environment} follows [environment].
    {!relay_label} follows [labels]. *)

val publishes_agent :
  base_path:string -> guest_name:string -> Keeper_microvm_boot_plan.facts -> bool
(** Whether a running guest publishes {!guest_path} at {!host_path}, read from
    what the runtime reports rather than from a plan. A reader attaches without
    assessing the guest, so it asks this before it reaches the guest through
    the agent. A guest that does not publish the agent has another plan, and
    its keeper's next turn replaces it. *)

type agent_check =
  | Agent_answered
  | Agent_unusable of string
      (** no hello within the connect budget, a hello this host refuses, an
          answer it cannot read, or a probe that did not exit 0 *)
  | Check_unavailable of string
      (** nothing was asked: this caller has no Eio network and clock, or
          passed a budget that is not finite and positive *)

val check_agent :
  host_socket:string -> expected:Keeper_guest_socket.expected ->
  connect_budget_sec:float -> budget_sec:float -> agent_check
(** One [Probe] through the agent's socket (RFC 3.6): what an attach reads
    before it adopts a running agent guest, since attaching does not go
    through the boot plan assessment. Only [Agent_unusable] says anything
    about the guest. *)

type preparation_error =
  | Directory_unusable of
      { path : string
      ; detail : string
      }
  | Socket_path_unusable of
      { path : string
      ; detail : string
      }
  | Path_occupied of { path : string }  (** something other than a socket *)
  | Guest_presence_unknown of string
  | Guest_still_present
      (** a guest of this name is listed, so the socket may be its own *)

val preparation_error_message : preparation_error -> string

val prepare_host_socket :
  guest_presence:(unit -> (Keeper_microvm_guest_inventory.presence, string) result) ->
  string ->
  (unit, preparation_error) result
(** Run just before the boot that publishes [path]. Its directory is made,
    or kept, a directory of this uid with mode 0700. A socket file already at
    [path] stops [container run] (RFC 4.5); the runtime removes the file when
    a guest ends cleanly, so one is left only by a guest that did not. It is
    removed only when [guest_presence] reports the guest absent, read only
    when there is a file to remove. Anything at [path] that is not a socket is
    refused rather than removed. *)
