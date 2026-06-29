(** SSOT typed composition of the per-cycle turn-admission preconditions.

    Composes the fd and disk pressure circuit-breakers into a single
    {!decision} so the heartbeat loop has ONE place that answers "may this
    keeper run a turn this cycle". New pressure sources (memory, cpu, quota)
    must be added here rather than as new inline gates in the loop, so the
    decision stays a closed sum the compiler checks exhaustively. *)

type block =
  | Fd of Keeper_fd_pressure.admission_block
  | Disk of Keeper_disk_pressure.admission_block

type decision =
  | Admitted
  | Blocked of block

(** Pure composition of the two circuit-breaker decisions. fd takes priority
    over disk when both block (fd exhaustion is the more acute process-level
    resource). All four input pairs are matched explicitly — adding an
    [admission_decision] variant to either module is a compile error here. *)
val decide_with
  :  fd:Keeper_fd_pressure.admission_decision
  -> disk:Keeper_disk_pressure.admission_decision
  -> decision

(** Impure shell: reads the live fd + disk admission decisions (each backed by
    its module's existing process-global cache — no extra probe) and composes
    them. [active_keepers] feeds the fd projection; [masc_root] the disk df. *)
val decide : masc_root:string -> active_keepers:int -> unit -> decision

(** Stable kind tag for the blocking source, e.g. ["disk:disk_free_space_low"]
    or ["fd:fd_pressure_cooldown"]. Display / skip-reason only; never parsed
    back into a decision. *)
val block_kind : block -> string

(** Human-readable one-line summary carrying the typed numbers (no re-probe). *)
val block_summary : block -> string

(** Prefix of every {!skip_reason} (named constant, not a free-form string). *)
val turn_admission_skip_prefix : string

(** Skip-reason stamped on the registry for a blocked keeper:
    [turn_admission_skip_prefix ^ block_kind block]. *)
val skip_reason : block -> string
