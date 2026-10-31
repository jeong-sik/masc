(* Closed Kata VMM identity — host-validated runtime IDs only.
   [task-2856] QEMU, Cloud Hypervisor and Dragonball are distinct containerd
   runtimes.  Upstream Kata does not apply a CRI ConfigPath through nerdctl, so
   a Keeper must not be able to invent a runtime id or a config path: the only
   accepted values are the ones this host validates below.  Anything else is a
   mismatch to report, never a value to adopt. *)

type vmm =
  | Qemu
  | Cloud_hypervisor
  | Dragonball

(* Host-validated closed mapping: runtime id -> VMM.  The per-VMM ids below
   exist only for Keepers that declared a VMM; the default Kata shim (no
   per-VMM split) carries no VMM claim at all — which VMM it boots is a
   configuration.toml value this host does not observe, so we do not guess. *)
let runtime_id_of = function
  | Qemu -> "io.containerd.kata-qemu.v2"
  | Cloud_hypervisor -> "io.containerd.kata-clh.v2"
  | Dragonball -> "io.containerd.kata-dragonball.v2"

let default_shim_runtime_id = "io.containerd.kata.v2"

(* What the caller should do with an observed runtime id.  [Default_shim]
   asserts no VMM: the shim's VMM depends on guest configuration this host
   does not read.  [Unknown_runtime] keeps the mismatch explicit instead of
   silently dropping or adopting the row. *)
type observed =
  | Ours of vmm                     (* one of the closed per-VMM ids above *)
  | Default_shim                    (* default shim; VMM unobserved, do not guess *)
  | Unknown_runtime of string       (* not an id this host validates or supports *)

(* The single classification entry point: everything else in this module and
   every consumer decision derives from this match. *)
let classify_runtime_id id =
  if String.equal id default_shim_runtime_id then Default_shim
  else
    match id with
    | "io.containerd.kata-qemu.v2" -> Ours Qemu
    | "io.containerd.kata-clh.v2" -> Ours Cloud_hypervisor
    | "io.containerd.kata-dragonball.v2" -> Ours Dragonball
    | _ -> Unknown_runtime id

(* Derived, for tests and diagnostics: the full validated set.  Other
   Kata-family ids exist upstream — kata-deploy also registers Firecracker as
   [io.containerd.kata-fc.v2] — and those are known-unsupported here, not
   somebody else's containers.  Consumers must report them as unsupported,
   never as foreign or adoptable. *)
let kata_runtime_ids =
  default_shim_runtime_id :: [ runtime_id_of Qemu; runtime_id_of Cloud_hypervisor;
                               runtime_id_of Dragonball ]

let vmm_name = function
  | Qemu -> "qemu"
  | Cloud_hypervisor -> "cloud-hypervisor"
  | Dragonball -> "dragonball"

(* Keeper-visible choice: only these three, spelled exactly.  Any other wire
   value is refused here rather than reaching containerd. *)
let vmm_of_choice = function
  | "qemu" -> Ok Qemu
  | "cloud-hypervisor" -> Ok Cloud_hypervisor
  | "dragonball" -> Ok Dragonball
  | other -> Error ("unknown kata vmm: " ^ other)
