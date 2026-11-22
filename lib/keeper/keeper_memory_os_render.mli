(** Exact Memory OS prompt rendering. *)

val render_facts : Keeper_memory_os_types.fact list -> string
val render_fact : Keeper_memory_os_types.fact -> string

val facts_payload_bytes :
  ordinary_facts:Keeper_memory_os_types.fact list -> source_lines:string list -> int
(** Bytes of the joined facts lines. Commit callers reserve source lines with
    [verified=false], the longest rendering recall can emit for them. *)

(** Whether the file-source store adds lines to the payload. *)
type facts_source_usage =
  | No_source_memory
  | Source_memory of { bytes : int }
      (** {!facts_payload_bytes} of the source lines alone. *)

(** One measurement of the rendered facts payload. [total_bytes] is
    {!facts_payload_bytes} of the ordinary facts and the source lines together,
    which {!evaluate_facts_budget} compares with [maximum_bytes] to decide
    whether to emit a non-blocking structural molt signal; the parts are the
    same function over each side alone, so [total_bytes] exceeds their sum by
    the one newline that joins them when both are present. *)
type facts_budget =
  { maximum_bytes : int
  ; ordinary_bytes : int
  ; source : facts_source_usage
  ; total_bytes : int
  }

val measure_facts_budget :
  maximum_bytes:int
  -> ordinary_facts:Keeper_memory_os_types.fact list
  -> source_lines:string list
  -> facts_budget
(** The Librarian prompt shows this measurement and the commit evaluates it, so
    the two cannot disagree about one set of facts and source lines. *)

val facts_budget_fits : facts_budget -> bool
(** Whether [total_bytes] fits [maximum_bytes]. *)

(** Multiplier applied to [maximum_bytes] to compute the emergency hard
    backstop enforced ONLY when the Librarian molt receiver is uninstalled or
    in [Stopped _] state ([4], i.e. 2 MiB for the default 512 KiB soft
    threshold). *)
val hard_backstop_multiplier : int

(** Overflow-safe emergency hard backstop in bytes ([maximum_bytes * 4]). *)
val hard_backstop_bytes : maximum_bytes:int -> int

(** Why the emergency hard backstop engaged on a growing commit past
    [hard_backstop_bytes]. *)
type molt_receiver_unavailable_reason =
  | Receiver_uninstalled
  | Receiver_stopped

(** Commit evaluation against the configured soft molt threshold (default
    512 KiB via [Env_config.KeeperMemoryOs.facts_max_bytes] /
    [MASC_KEEPER_MEMORY_OS_FACTS_MAX_BYTES]).
    - When a healthy Librarian receiver is installed and running (Idle, Asking,
      Resting, Booting), commits past [maximum_bytes] are NEVER hard-rejected;
      they return [Molt_recommended] so consolidation runs asynchronously.
    - When the molt receiver is uninstalled or [Stopped _], growth between
      [maximum_bytes] and [4x maximum_bytes] logs a warning and proceeds while
      latching molt, and growth past [4x maximum_bytes] fails closed with
      [Backstop_exceeded] so Memory OS cannot grow unboundedly without an
      active consolidator. Shrinking or unchanged passes always return
      [Within_threshold] so retraction/cleanup can always recover. *)
type facts_budget_outcome =
  | Within_threshold of facts_budget
  | Molt_recommended of facts_budget
  | Backstop_exceeded of
      { budget : facts_budget
      ; hard_limit_bytes : int
      ; reason : molt_receiver_unavailable_reason
      }

val backstop_rejection_message
  :  budget:facts_budget
  -> hard_limit_bytes:int
  -> reason:molt_receiver_unavailable_reason
  -> string

val evaluate_facts_budget :
  keeper_id:string
  -> previous_bytes:int
  -> ordinary_facts:Keeper_memory_os_types.fact list
  -> source_lines:string list
  -> facts_budget_outcome
(** Evaluate a proposed current fact set against the configured soft threshold
    and, when no live molt receiver is active for [keeper_id], the 4x emergency
    hard backstop. Never refuses shrinking or unchanged passes and never spins
    when the set did not strictly grow above [previous_bytes]. *)

val set_on_molt_requested :
  (keeper_id:string -> facts_budget -> unit) option -> unit
(** Register or clear the non-blocking callback notified after a commit
    crosses the soft molt threshold (wired to [Librarian_writers.request_molt]
    in [Keeper_memory_writers]). *)

val set_is_molt_receiver_stopped :
  (keeper_id:string -> bool) option -> unit
(** Register or clear the read-only predicate reporting whether [keeper_id]'s
    Librarian writer is currently [Stopped _] (wired to
    [Librarian_writers.is_stopped] in [Keeper_memory_writers]). *)

val notify_molt_if_recommended :
  keeper_id:string -> facts_budget_outcome -> unit
(** Invoke the registered molt callback if [outcome] is [Molt_recommended _]
    (or log [Log.Keeper.warn] if the receiver is uninstalled). Callers must
    invoke this ONLY after all Memory OS locks have unwound. *)
