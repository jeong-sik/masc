(** Closed Kata VMM identity: host-validated runtime ids only.

    A Keeper chooses among [Qemu], [Cloud_hypervisor] and [Dragonball] by
    name; the host maps that choice to a runtime id from a closed set.  The
    Keeper never supplies a runtime id or a configuration path.  Observed
    inventory rows are classified against the same closed set, and anything
    outside it stays an explicit [Unknown_runtime] mismatch. *)

type vmm =
  | Qemu
  | Cloud_hypervisor
  | Dragonball

val runtime_id_of : vmm -> string
(** The per-VMM containerd runtime id this host validates. *)

val default_shim_runtime_id : string
(** The unsplit Kata shim id used by existing guests. *)

val vmm_of_runtime_id : string -> vmm option
(** [Some vmm] for the closed per-VMM ids, [None] otherwise. *)

val kata_runtime_ids : string list
(** Every Kata-family runtime id this host validates, including the default
    shim.  Closed: nothing outside this list is ours. *)

val is_kata_runtime_id : string -> bool

type observed =
  | Ours of vmm
  | Default_shim of vmm  (** the default shim, whose VMM is [Qemu] today *)
  | Unknown_runtime of string

val classify_runtime_id : string -> observed
(** Classify an observed runtime id against the closed set without adopting
    or dropping it. *)

val vmm_name : vmm -> string

val vmm_of_choice : string -> (vmm, string) result
(** The Keeper-facing choice decoder: exactly three names, nothing else. *)
