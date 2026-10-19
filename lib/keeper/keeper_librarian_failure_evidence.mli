(** Pure evidence collected from every failed visit of a Librarian walk.
    Historical range sizing and admission partitioning remain independent. *)

type t = private
  { historical_range_size : bool
  ; named_input_capacity : bool
  ; invalid_output : bool
  ; size_independent_execution_failure : bool
  ; measured_cli_capacity : Keeper_lane_cli_oneshot.input_capacity option
  ; provider_input_refusals : Keeper_librarian_input_refusal.t list
      (** Distinct, canonically ordered named causes across the walk. These are
          observations, not permission to consume any part of an unread range.
          In particular, invalid output and uncertain execution remain separate. *)
  }

val empty : t
val invalid_output : t
val input_capacity_refusal : t
val with_invalid_output : t -> t
val without_measured_cli_capacity : t -> t

val shows_range_size : t -> bool
val refuses_input_capacity : t -> bool
(** Invalid output vetoes both derived decisions without erasing independent
    execution failures or measured CLI limits. *)

val of_cause : Agent_core.Exact_output.execution_error_cause -> t
val of_disposition : Agent_core.Exact_output.candidate_rejection_disposition -> t
val of_flow :
  'callback_error Agent_core.Exact_output.flow_execution_error ->
  Agent_core.Exact_output.flow_evidence * t
(** Fold final-cause and advance evidence once. Candidate rejection is not a
    size-independent execution failure. The returned flow evidence also owns
    the generation-dispatch fact; token measurement is not generation. *)

val of_cli_failure : Keeper_lane_cli_oneshot.failure -> t
val after_cli_fallback : prior:t -> Keeper_lane_cli_oneshot.failure list -> t
(** Preserve prior policy evidence while classifying the current CLI walk in
    order. Only this walk supplies [measured_cli_capacity]; an earlier nested
    fallback's limit is not inherited. Choose the largest measured character
    limit, preserving the first slot when capacities tie. *)
