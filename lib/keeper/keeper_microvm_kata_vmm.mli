(** Closed Kata VMM identity: host-validated runtime ids only.

    A Keeper chooses among [Qemu], [Cloud_hypervisor] and [Dragonball] by
    name; the host maps that choice to a runtime id from a closed set.  The
    Keeper never supplies a runtime id or a configuration path.  Observed
    inventory rows are classified through [classify_runtime_id] — the single
    classification entry point — and anything outside the validated set stays
    an explicit [Unknown_runtime] mismatch (known-unsupported Kata family,
    e.g. Firecracker, or a foreign runtime alike). *)

type vmm =
  | Qemu
  | Cloud_hypervisor
  | Dragonball

val runtime_id_of : vmm -> string
(** The per-VMM containerd runtime id this host validates. *)

val default_shim_runtime_id : string
(** The unsplit Kata shim id used by existing guests. *)

type observed =
  | Ours of vmm
  | Default_shim
      (** The default Kata shim.  Carries no VMM claim: which VMM it boots is
          guest configuration this host does not observe, so callers must not
          display or record a VMM for it. *)
  | Unknown_runtime of string

val classify_runtime_id : string -> observed
(** Classify an observed runtime id against the closed set without adopting
    or dropping it.  This is the single classification entry point; derive
    every ownership or reporting decision from its result rather than from
    separate membership tests. *)

val kata_runtime_ids : string list
(** Every Kata-family runtime id this host validates and supports, including
    the default shim.  Ids outside this list are unsupported or foreign —
    never adoptable; report them via {!classify_runtime_id}. *)

val vmm_name : vmm -> string

val vmm_of_choice : string -> (vmm, string) result
(** The Keeper-facing choice decoder: exactly three names, nothing else. *)
