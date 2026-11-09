(** microVM argv for the [Micro_vm] sandbox profile.

    Every builder here takes the runtime the keeper declared
    ({!Keeper_microvm_backend.t}). Before #32837 the lifecycle surfaces took
    it and the boot, exec, image and listing surfaces did not, so a keeper
    naming [microsandbox] booted under Apple's [container] and was then
    stopped and inspected with [msb] -- two runtimes for one guest, and
    nothing able to reap the one that actually booted.

    One lightweight VM per container through Virtualization.framework, so an
    Apple guest runs its own Linux kernel instead of sharing the host's.
    Measured
    2026-08-28 on macOS 26.6.1 / M3 Max with container CLI 1.3.0: about
    460 MB of host memory per running guest, and the guest reporting
    [Linux <uuid> 6.18.35].

    Cost is per keeper, not per call. Booting a guest takes 1.3-2.4s, but
    #31340 made the guest keeper-lifetime, so a turn pays [container exec]
    at 0.06-0.10s -- under Docker's 0.6-0.9s per-call container start. An
    earlier version of this comment quoted 4.0-4.4s per call: that was
    measured before guests were adopted across turns, and stayed here after
    the number stopped being true.

    This module builds the command and nothing else; [Keeper_turn_sandbox_runtime]
    runs the boot and lifecycle argv, and the remote lane
    ([Keeper_sandbox_remote]) drives the guest's shim over [container exec].
    The guest's working tree is on a Keeper-named volume (RFC-0400), which
    can be shared by same-named Keepers in different workspaces. The host
    playground is never mounted into it.

    The definitions live in the [Keeper_sandbox_microvm_*] modules included
    below, one per topic. [keeper_sandbox_microvm.mli] stays the contract. *)

include Keeper_sandbox_microvm_base
include Keeper_sandbox_microvm_network
include Keeper_sandbox_microvm_image_probe
include Keeper_sandbox_microvm_guest_argv
include Keeper_sandbox_microvm_work_volume
include Keeper_sandbox_microvm_shim
include Keeper_sandbox_microvm_volume_probe
include Keeper_sandbox_microvm_volume_claim_scripts
include Keeper_sandbox_microvm_volume_claims
include Keeper_sandbox_microvm_work_root
include Keeper_sandbox_microvm_inspect
include Keeper_sandbox_microvm_inventory
include Keeper_sandbox_microvm_listing

