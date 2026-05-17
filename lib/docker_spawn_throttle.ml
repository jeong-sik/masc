(** See .mli for contract.

    RFC-0101 PR-2: thin delegate to {!Fd_accountant}. The original
    PR #15727 implementation (env knob + Eio.Semaphore +
    pressure-aware Eio.Mutex) lives unchanged in
    [Fd_accountant.with_slot ~kind:Docker_spawn]; this module is the
    legacy public API preserved for in-tree callers. Removal scheduled
    after one release cycle. *)

let with_slot f = Fd_accountant.with_slot ~kind:Docker_spawn f

let effective_concurrency () =
  Fd_accountant.effective_concurrency ~kind:Docker_spawn

let configured_max () =
  Fd_accountant.configured_concurrency ~kind:Docker_spawn
