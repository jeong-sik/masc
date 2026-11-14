(* RFC-0489 §2.3 — the Goal-side phase view. One module owns every
   [Lane_addon_request_progress.phase] match; consumers see only the typed
   phase above. Layer 1 decoding is total and behavior-preserving: it
   re-labels existing evidence, it never validates, rejects or rewrites it. *)

open Result.Syntax

module Progress = Lane_addon_request_progress

type run_identity = { run_id : string; started_at : float }

type observation = Waiting of Yojson.Safe.t | Outcome_unknown of Yojson.Safe.t
  | Absent of Yojson.Safe.t

type run_end = Cancelled | Raised | Retention_failed

type reviewer_refusal = { evidence : Yojson.Safe.t }

type refusal =
  | Reviewer_refused of reviewer_refusal
  | Run_ended of {
      cause : run_end
    ; run : run_identity
    ; tools : Verification_run_registry.tool_observation list
    ; observations : Yojson.Safe.t list
    }
  | Owner_exited of { run : run_identity }
  | Authority_moved of { detail : string }

type stage = Before_dispatch | Execution

type phase =
  | Captured
  | Admission_wait of Yojson.Safe.t
  | Dispatch_pending of observation option
  | Judged of Yojson.Safe.t
  | Committing of Lane_addon_request_progress.commit
  | Commit_unknown of Lane_addon_request_progress.commit * Yojson.Safe.t
  | Finished of Lane_addon_request_progress.commit
  | Conflicted of Lane_addon_request_progress.commit * Yojson.Safe.t
  | Rejected of { stage : stage; refusal : refusal }
  | Subdividing of refusal * Lane_addon_request_progress.successor
  | Subdivided of refusal * Lane_addon_request_progress.successor

(* The run codecs live here so layer 3's Run_ended/Owner_exited evidence and
   the worker's request encoding share one schema and one error surface. The
   scope keeps the worker's existing "goal-proof-reviews" field errors. *)
let scope = "goal-proof-reviews"
let text key fields = Json_util.require_field_string ~surface:scope key fields
let field key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (scope ^ "." ^ key ^ " is required")
let object_fields allowed = function
  | `Assoc fields ->
    let* () = Json_util.reject_unknown_fields ~surface:scope ~allowed fields in
    Ok fields
  | _ -> Error (scope ^ " must be an object")

let run_end_label = function
  | Cancelled -> "review_cancelled"
  | Raised -> "review_raised"
  | Retention_failed -> "goal_review_retention_failed"

let run_end_of_label = function
  | "review_cancelled" -> Ok Cancelled
  | "review_raised" -> Ok Raised
  | "goal_review_retention_failed" -> Ok Retention_failed
  | _ -> Error "unknown Goal review run end"

let run_json run = `Assoc ["run_id", `String run.run_id; "started_at", `Float run.started_at]

let run_of_json json =
  let* fields = object_fields ["run_id"; "started_at"] json in
  let* run_id = text "run_id" fields in
  let* started_at = Json_util.require_field_float ~surface:scope "started_at" fields in
  if Float.is_finite started_at then Ok {run_id; started_at}
  else Error "Goal verifier run time must be finite"

let observation = function
  | Progress.Waiting json -> Waiting json
  | Progress.Outcome_unknown json -> Outcome_unknown json
  | Progress.Absent json -> Absent json

let stage = function
  | Progress.Before_dispatch -> Before_dispatch
  | Progress.Execution -> Execution

(* Refusals are re-labeled, never decoded: the exact evidence bytes move into
   the typed wrapper (or into [detail] for the before-dispatch change) so the
   worker's existing validation reads the same structure as before. *)
let refusal_of stage evidence =
  match stage with
  | Progress.Before_dispatch -> Authority_moved {detail = Yojson.Safe.to_string evidence}
  | Progress.Execution -> Reviewer_refused {evidence}

let view (phase : Progress.phase) =
  match phase with
  | Progress.Captured -> Captured
  | Progress.Admission_wait json -> Admission_wait json
  | Progress.Dispatch_pending observation ->
    Dispatch_pending (Option.map observation observation)
  | Progress.Judged json -> Judged json
  | Progress.Committing commit -> Committing commit
  | Progress.Commit_unknown (commit, json) -> Commit_unknown (commit, json)
  | Progress.Finished commit -> Finished commit
  | Progress.Conflicted (commit, json) -> Conflicted (commit, json)
  | Progress.Rejected {stage; evidence} ->
    Rejected {stage = stage stage; refusal = refusal_of stage evidence}
  | Progress.Subdividing ({stage; evidence}, successor) ->
    Subdividing (refusal_of stage evidence, successor)
  | Progress.Subdivided ({stage; evidence}, successor) ->
    Subdivided (refusal_of stage evidence, successor)

let evidence_json = function
  | Reviewer_refused r -> r.evidence
  | Run_ended {cause; run; tools; observations} ->
    `Assoc ["cause", `String (run_end_label cause); "run", run_json run;
      "tools", `List (List.map Verification_run_registry.tool_observation_to_yojson tools);
      "observations", `List observations]
  | Owner_exited {run} -> `Assoc ["run", run_json run]
  | Authority_moved {detail} ->
    (try Yojson.Safe.from_string detail with _ -> `Null)
