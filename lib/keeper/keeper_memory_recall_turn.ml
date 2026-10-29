module Flow = Keeper_memory_recall_flow
module J = Keeper_memory_recall_judgment
module Evaluation = Keeper_memory_recall_evaluation

type t =
  | Off of Typesafeai_config.unavailable_reason
  | Nothing_to_judge
  | Judged of Flow.judged

(* ---- the judgment kept for its turn ---- *)

(* The turn owns the memo and a turn judges once, one fiber at a time, so the
   field needs no lock. *)
type memo = { mutable kept : (Ids.Turn_ref.t * Flow.judged) option }

let create_memo () = { kept = None }

let kept_for memo ~turn_ref =
  match memo.kept with
  | Some (kept_turn_ref, judged) when Ids.Turn_ref.equal kept_turn_ref turn_ref -> Some judged
  | Some _ | None -> None

let keep memo ~turn_ref judged = memo.kept <- Some (turn_ref, judged)

(* An [unavailable] judgment decided nothing usable, so a retry within the turn
   asks again. Any other status already says how much it covered: the status
   line shows "M of N judged" for a partial one. *)
let is_kept_for_its_turn (judged : Flow.judged) =
  match judged.status with
  | J.Selected _ | J.None_found _ | J.None_needed _ -> true
  | J.Unavailable _ -> false

(* ---- metrics ---- *)

(* Histogram schema, not a limit on a judgment: the client's own timeout ends
   each request. A judgment is one round of requests, or two when question (c)
   follows, and more after a request is cut again (RFC section 4.8). *)
let judgment_seconds_upper_bounds =
  [ 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0; 20.0; 40.0; 80.0 ]

let () =
  Otel_metric_store.register_histogram_buckets
    Keeper_metrics.(to_string MemoryRecallJudgmentSeconds)
    judgment_seconds_upper_bounds

let record_judgment ~keeper_id ~seconds (judged : Flow.judged) =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string MemoryRecallTotal)
    ~labels:[ "keeper", keeper_id; "outcome", J.status_token judged.status ]
    ();
  (match judged.status with
   | J.Selected { selection; coverage = _; turn_question_contradicted = _ } ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string MemoryRecallSelected)
       ~labels:[ "keeper", keeper_id ]
       ~delta:(Float.of_int (List.length (J.selection_ids selection)))
       ()
   | J.None_found _ | J.None_needed _ | J.Unavailable _ -> ());
  Otel_metric_store.observe_histogram
    Keeper_metrics.(to_string MemoryRecallJudgmentSeconds)
    ~labels:[ "keeper", keeper_id ]
    seconds

(* ---- the judgment ---- *)

let judge_with ~evaluate ~memo ~config ~keeper_id ~turn_ref ~purpose candidates =
  match Typesafeai_config.memory_recall_destinations ~keeper_id with
  | Error reason -> Ok (Off reason)
  | Ok destinations ->
    (match kept_for memo ~turn_ref with
     | Some judged -> Ok (Judged judged)
     | None ->
       let record = Evaluation.create ~config ~keeper_id ~turn_ref ~destinations in
       let began = Time_compat.now () in
       (match Flow.run ~evaluate:(evaluate record) ~purpose candidates with
        | Error build_error -> Error build_error
        | Ok None -> Ok Nothing_to_judge
        | Ok (Some judged) ->
          let judged = Evaluation.retain_outcome record judged in
          record_judgment ~keeper_id ~seconds:(Time_compat.now () -. began) judged;
          if is_kept_for_its_turn judged then keep memo ~turn_ref judged;
          Ok (Judged judged)))

let judge ?clock ~memo ~config ~keeper_id ~turn_ref ~purpose candidates =
  judge_with
    ~evaluate:(fun record -> Evaluation.evaluate ?clock record)
    ~memo
    ~config
    ~keeper_id
    ~turn_ref
    ~purpose
    candidates
