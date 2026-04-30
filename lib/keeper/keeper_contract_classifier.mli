(** Typed classifier for keeper turn completion contract. *)

type actionable_signal =
  | Has_unclaimed_tasks
  | Has_board_activity
  | Has_discovered_work
  | No_actionable_signal
      (** Caller observed neither tasks, board activity, nor
          discovered-work markers in the structured world snapshot. *)

type contract_status =
  | Tool_surface_mismatch of { missing : string list }
  | Missing_required_tool_use
  | Claim_only_after_owned_task
  | Needs_execution_progress
  | Passive_only
  | Satisfied_completion
  | Satisfied_execution

val actionable_signal_label : actionable_signal -> string
val contract_status_label : contract_status -> string
val pp_contract_status : Format.formatter -> contract_status -> unit

(** Structured per-turn world snapshot consumed by
    [classify_actionable_signal].  These values are observed before prompt
    rendering so the completion-contract gate does not infer world state
    from rendered prose. *)
type world_observation = {
  unclaimed_task_count : int;
      (** Number of unclaimed tasks in the keeper's queue.
          Mirrors the integer rendered into the
          ["**Unclaimed tasks (N total ...) ..."] section. *)
  board_activity_count : int;
      (** Count of fresh board entries the keeper has not yet
          processed. Mirrors the count rendered after
          ["### Board Activity"]. *)
  has_discovered_work_section : bool;
      (** True iff the prompt build emitted a
          ["## Discovered Work (auto, Ns interval)"] section. *)
}

(** [classify_actionable_signal o] returns the most-specific
    actionable signal observed in [o], following the precedence
    [unclaimed_tasks > board_activity > discovered_work].

    The precedence reflects the action ladder a keeper should
    descend: a claimable task is the highest-leverage move; engaging
    with board activity is next; discovery hints are the weakest
    signal. The current heuristic at [keeper_agent_run.ml:2285-2298]
    short-circuits as a single boolean and discards the precedence;
    routing decisions made on top of [actionable_signal] can choose
    differently for each variant.

    Boolean-compatible:
    [classify_actionable_signal o <> No_actionable_signal]
    is the structured equivalent of the existing
    [actionable_signal_context = true]. *)
val classify_actionable_signal : world_observation -> actionable_signal

(** Like [classify_actionable_signal], but skips a candidate signal when
    the active tool surface has no tool capable of acting on that signal.

    This preserves the documented precedence while avoiding unwinnable
    contract violations. Example: if unclaimed tasks exist but the keeper
    cannot see a claim tool, board activity can still become the selected
    actionable signal when board tools are visible. *)
val classify_actionable_signal_with_allowed_tools :
  allowed_tool_names:string list -> world_observation -> actionable_signal

(** [is_actionable s] is [false] iff [s = No_actionable_signal].
    Provided so callers comparing the structured signal against the
    legacy boolean can do so without a manual pattern match. *)
val is_actionable : actionable_signal -> bool
