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

(* Host-validated closed mapping: runtime id -> VMM.  The default Kata shim
   (no per-VMM split) maps to [Qemu] because that is the Kata default VMM;
   the derived per-VMM ids exist only for Keepers that declared one. *)
let runtime_id_of = function
  | Qemu -> "io.containerd.kata-qemu.v2"
  | Cloud_hypervisor -> "io.containerd.kata-clh.v2"
  | Dragonball -> "io.containerd.kata-dragonball.v2"

let default_shim_runtime_id = "io.containerd.kata.v2"

let vmm_of_runtime_id id =
  match id with
  | "io.containerd.kata-qemu.v2" -> Some Qemu
  | "io.containerd.kata-clh.v2" -> Some Cloud_hypervisor
  | "io.containerd.kata-dragonball.v2" -> Some Dragonball
  | _ -> None

(* All runtime ids that belong to the Kata family on this host: the default
   shim plus the per-VMM splits.  An inventory row carrying any other id is
   not ours; a row carrying one of these is one of ours whatever else it
   says.  The set is closed: there is no fourth id to invent. *)
let kata_runtime_ids =
  default_shim_runtime_id :: [ runtime_id_of Qemu; runtime_id_of Cloud_hypervisor;
                               runtime_id_of Dragonball ]

let is_kata_runtime_id id = List.mem id kata_runtime_ids

(* What the caller should do with an observed runtime id, given what the
   Keeper declared.  [Unknown] keeps the mismatch explicit instead of
   silently dropping or adopting the row. *)
type observed =
  | Ours of vmm                     (* one of the closed ids above *)
  | Default_shim of vmm             (* default shim; [Qemu] is its VMM today *)
  | Unknown_runtime of string       (* not a Kata id this host validates *)

let classify_runtime_id id =
  if String.equal id default_shim_runtime_id then Default_shim Qemu
  else
    match vmm_of_runtime_id id with
    | Some vmm -> Ours vmm
    | None -> Unknown_runtime id

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
