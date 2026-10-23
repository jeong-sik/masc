(** Paired offline measurement through the actual Librarian inference lane.
    Source inputs are explicitly synthetic complete captures. No private
    history discovery, progress cursor publication or runtime gate occurs. *)
module R = Librarian_continuity_report
module S = Librarian_continuity_snapshot
module L = Keeper_librarian_runtime

type case =
  { id : string
  ; source : Keeper_librarian.input
  ; previous_state : string option
  ; unread_messages : Keeper_librarian_unread.t list
  ; suffix : Agent_core.Types.message list
  ; question : string
  }
type dataset = { provenance : R.provenance; cases : case list }
type work = Work_not_started | Work_started | Work_finished of L.working_state_inference
type snapshot = Snapshot_not_started | Snapshot_failed of string | Snapshot_ready of S.t
type progress =
  { work : work; selected_source : Keeper_librarian.input option
  ; snapshot : snapshot; baseline : R.progress; restored : R.progress }

val initial_progress : progress
val parse_dataset : Yojson.Safe.t -> (dataset, string) result
val case_to_yojson : case -> Yojson.Safe.t
val progress_to_yojson : progress -> Yojson.Safe.t
val evaluate_case
  : infer:(previous_state:string option
           -> unread_messages:Keeper_librarian_unread.t list
           -> Keeper_librarian.input -> L.working_state_inference)
  -> generate:(R.prompt -> (R.generation, R.failed_generation) result)
  -> judge:(R.judge_request -> (R.judgment, string) result)
  -> judge_endpoint:string -> judge_model:string -> snapshot_path:string
  -> save:(progress -> (unit, string) result)
  -> case -> (progress, string) result
(** Inference receives only the source prefix, previous state and explicit
    holes. Declared holes are bound to the complete source history and omitted
    from its inference messages; historical task message offsets follow the
    retained messages. The exact selected input is retained in the report.
    The question and future suffix are unavailable to it. Preparation
    is captured by the inference pass itself, never re-rendered here.
    The successful state is saved, loaded and restored by the production
    snapshot codec. Both answer arms share current Memory, Keeper context,
    question, answer provider and judge. The baseline retains the full source
    plus the prior state; restoration uses the new state plus the suffix.
    Prior state is opaque input, not proof of any earlier source coverage.

    The boundary is explicitly synthetic; official-client fragment and live
    continuity evidence remain separate. Failed inference or restoration
    still permits the baseline; either answer/judge failure preserves the
    other arm. Every transition is saved before the next effect. Save failures
    stop immediately. Cancellation propagates, leaving Work_started in the
    last durable report rather than inventing a failed provider response. *)
