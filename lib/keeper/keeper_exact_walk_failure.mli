(** Pure host evidence collected from every failed visit of an exact walk.
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

(** Closed immutable source observations. Projected from real typed host
    causes, never from diagnostic text or worker decisions. *)
type api_observation
val api_observation : Agent_core.Exact_output.execution_error_cause -> api_observation
val api_observation_to_yojson : api_observation -> Yojson.Safe.t
val api_observation_of_yojson : Yojson.Safe.t -> (api_observation,string) result
val of_api_observation : api_observation -> t
val dispatched_valid_output_failure : api_observation -> bool

(** Context refusals retain their actual native flags (and original message),
    so decoding rederives safe named-capacity evidence rather than accepting a
    precomputed authority boolean. Measured input limits remain separate. *)
type cli_observation
val cli_observation : Keeper_lane_cli_oneshot.failure -> cli_observation
val cli_observation_to_yojson : cli_observation -> Yojson.Safe.t
val cli_observation_of_yojson : Yojson.Safe.t -> (cli_observation,string) result
val of_cli_observation : cli_observation -> t
val cli_observation_slot : cli_observation -> string
val cli_was_dispatched : cli_observation -> bool
(** The original per-slot runner observes dispatch before native execution or
    output validation, but never for an unresolved/non-official runtime. *)
val combine : t -> t -> t

type local_rejection = Runtime_unavailable | Runtime_contract | Input_contract
  | Output_requirement | Local_input_capacity | Preparation_failed
[@@deriving yojson]
val local_rejection : Agent_core.Exact_output.candidate_rejection_disposition -> local_rejection
val of_local_rejection : local_rejection -> t

val api_generation_dispatched : api_observation -> bool
