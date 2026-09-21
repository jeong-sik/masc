(** Explicit synthetic paired evaluation; no runtime prompts or cursors change. *)
module R = Librarian_continuity_report
module S = Librarian_continuity_snapshot

type case =
  { id : string; trace_id : string; absolute_turn : int
  ; prefix : Agent_core.Types.message list; suffix : Agent_core.Types.message list
  ; facts : R.fact list; question : string }
type dataset = { provenance : R.provenance; cases : case list }
type work = Work_not_started | Work_failed of R.failed_generation | Work_ready of R.generation
type snapshot = Snapshot_not_started | Snapshot_failed of string | Snapshot_ready of S.t
type progress =
  { work : work; snapshot : snapshot; baseline : R.progress; restored : R.progress }

val initial_progress : progress
val parse_dataset : Yojson.Safe.t -> (dataset, string) result
val case_to_yojson : case -> Yojson.Safe.t
val progress_to_yojson : progress -> Yojson.Safe.t
val evaluate_case
  : generate:(R.prompt -> (R.generation, R.failed_generation) result)
  -> judge:(R.judge_request -> (R.judgment, string) result)
  -> judge_endpoint:string -> judge_model:string -> snapshot_path:string
  -> save:(progress -> (unit, string) result)
  -> case -> (progress, string) result
(** Working state sees prefix only. Both answer arms see the same question;
    both arms receive the same existing Memory facts. Save failures stop immediately, while an
    arm's generation or judgment failure does not suppress the other arm.
    The snapshot boundary is synthetic, not evidence about a live Keeper. *)
