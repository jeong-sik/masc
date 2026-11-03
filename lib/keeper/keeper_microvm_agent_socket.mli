(** The guest agent of an Apple microVM keeper, seen from its boot (RFC
    microvm-guest-agent-over-socket 3.2, 3.6): where its socket is on both
    sides, the boot plan that starts it, and the host path made ready just
    before that boot. *)

val guest_path : string
(** Where the agent binds inside the guest. It is on the root filesystem:
    [--publish-socket] does not reach a socket on a tmpfs, a named volume or
    a host directory mount (RFC 4.2). *)

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
  uid:int -> gid:int -> host_socket:string -> Keeper_microvm_boot_plan.t ->
  Keeper_microvm_boot_plan.t
(** The agent form of an exec-per-request plan (RFC 0, 3.2). The first
    process is [masc-exec-shim --serve] started as [0:0]; it binds
    {!guest_path}, re-mounts the root read-only and drops to [uid:gid]. So the
    plan leaves out [Read_only_rootfs], gives back [CAP_SETUID], [CAP_SETGID]
    and [CAP_SYS_ADMIN] after dropping all, and publishes the socket at
    [host_socket]. The agent hands its own environment and working directory
    to every request, so {!Keeper_sandbox_microvm.request_environment}, which
    an exec request gets as [--env], is in the plan's environment. Everything
    else is the exec plan's. *)

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
