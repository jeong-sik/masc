(** Which microVM runtime serves the [Micro_vm] sandbox profile.

    The profile says a keeper's tree lives on a guest behind a hypervisor
    boundary ([Endpoint_owned], network closed by default, reads and writes
    over the remote lane). It does not say which runtime provides that guest,
    and until RFC-0405 one runtime was assumed: Apple's [container], which
    exists only on macOS 26+.

    A backend answers the argv this codebase already builds — the CLI shape
    consumers reach through {!Keeper_sandbox_microvm} — and the parse of what
    that CLI reports back. Everything above that line is shared: the work
    volume, the shim mount, the identity snapshot, the session ceiling. Those
    are RFC-0400's model of a guest, and they do not change with the
    hypervisor under it. *)

type t =
  | Apple_container
      (** [container] (Apple Containerization, macOS 26+). One VM per
          container through Virtualization.framework. *)
  | Microsandbox
      (** [msb] (microsandbox, libkrun). Runs where KVM is available, which
          includes Linux — the platform Apple's runtime cannot serve. *)
  | Nerdctl_kata
      (** [nerdctl] driving containerd with the Kata Containers runtime. A
          Kata pod is a microVM with its own kernel and a [kata-agent] that
          takes OCI Exec over vsock, so a guest can be booted detached and
          driven across turns the way the other two are. The CLI is Docker's
          grammar, and [nerdctl inspect] defaults to [--mode dockercompat],
          so this backend reuses the Docker state format rather than needing
          a parse of its own. *)

val to_string : t -> string
val of_string : string -> t option
val all : t list

val valid_strings : string list
(** The accepted spellings, for a schema mirror and for a refusal that can
    name what it would have taken. *)

val run_runtime_args : t -> string list
(** Extra argv the boot needs to get a microVM rather than whatever the CLI
    would default to. Apple's [container] and [msb] are microVM runtimes by
    construction and answer none; [nerdctl] drives containerd, whose default
    is a shared-kernel runtime, so the Kata shim has to be named or the guest
    would be a container wearing this profile's name. *)

val cli_name : t -> string
(** The executable this backend drives. A backend whose CLI is absent is
    refused rather than substituted, so the name reaches the refusal. *)

val default_for_host : unit -> t option
(** The backend to assume when a keeper declares [Micro_vm] without naming
    one. [Some Apple_container] on macOS, where that runtime is the platform
    answer; [None] elsewhere, so a keeper on a host with no assumed backend
    is refused at boot instead of silently taking a different isolation than
    the one it declared. *)

(** {2 What the boot asks the runtime to guarantee} *)

type guest_constraint =
  | Drop_all_capabilities  (** No capability is retained inside the guest. *)
  | Read_only_rootfs  (** The guest's root filesystem rejects writes. *)
  | Remove_on_exit
      (** The runtime removes the guest when its process exits, so a guest
          left behind by a host reboot does not hold the name. *)

val all_guest_constraints : guest_constraint list
(** Every guarantee, so a caller asks for the set rather than typing it and
    a boot cannot quietly ask for fewer than the lane documents. *)

val guest_constraint_to_string : guest_constraint -> string
(** The spelling that reaches a refusal message and the guest's drop label. *)

type constraint_class =
  | Isolation
  | Lifecycle

val constraint_class : guest_constraint -> constraint_class
(** [Isolation] for a guarantee whose absence weakens the sandbox the profile
    was chosen for; the boot refuses rather than run without one. [Lifecycle]
    for one teardown covers by other means; the boot records the drop on the
    guest and continues. *)

type constraint_argv =
  | Expressed of string list  (** The tokens this runtime spells it with. *)
  | Not_expressible of string
      (** Why this runtime cannot say it, in the operator's words. *)

val run_constraint_argv : t -> guest_constraint -> constraint_argv
(** How one runtime spells one guarantee on its [run], or why it cannot.
    Every pair is enumerated: a runtime added later has to answer each
    guarantee rather than inherit a default that would drop it. *)

val command_separator : t -> string list
(** What has to sit between this CLI's own arguments and the command the
    guest runs. [\["--"\]] for [msb], which otherwise reads the first word of
    the command as another option and stops; empty for [container] and
    [nerdctl], which take the command bare. *)

val exec_stdin_args : t -> string list
(** How this CLI is told to keep stdin open on an exec. [\["-i"\]] for
    [container] and [nerdctl]; [\["--stream"\]] for [msb], which rejects [-i]
    and spells the same thing without a PTY. *)
