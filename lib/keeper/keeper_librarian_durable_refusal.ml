module Request = Keeper_librarian_durable_request
module Retained = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Runtime = Keeper_librarian_runtime
module Consumer = Keeper_librarian_durable_consumer
module Source = Keeper_librarian_durable_capture
module Edge = Keeper_librarian_durable_edge
module Current = Keeper_memory_os_current
open Result.Syntax
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f
type t = {request_id:string;destination:Request.destination;refusal:Consumer.error}
let detail = function
  | Exact.Call_final (Answered _) -> "Unexpected answered result in original history refusal"
  | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
  | Outcome_unknown | Not_allowed _ | Request_id_reused as final ->
    "Original history request refused: " ^ Yojson.Safe.to_string (Exact.final_to_json final)
let report ~store request final =
  let detail=detail final in
  match io (fun () -> Request.refusal_evidence ~store request final) with
  | Ok evidence -> Runtime.not_committed_of_failure ~detail evidence
  | Error why -> Runtime.not_committed_of_failure
      ~detail:(detail ^ "; reading less could not be judged: " ^ why) Keeper_exact_walk_failure.empty
(* A later completed request has to contain each original observation, with
   multiplicity. A delivery preview is not equal to the original chat text. *)
let observations_cover original actual =
  let rec remove_one value = function
    | [] -> None
    | first :: rest when first = value -> Some rest
    | first :: rest -> Option.map (fun tail -> first :: tail) (remove_one value rest)
  in
  let rec contains remaining = function
    | [] -> true
    | first :: rest ->
      match remove_one first remaining with
      | None -> false
      | Some remaining -> contains remaining rest
  in
  contains actual original

let source_covers original actual =
  let atom = match Source.range_id original, Source.range_id actual with
    | None, (None | Some _) -> true
    | Some _, None -> false
    | Some (old : Current.durable_range_id), Some (newer : Current.durable_range_id) ->
      old.receipt_scope = newer.receipt_scope && old.trace_id = newer.trace_id
      && old.history_start_boundary_line = newer.history_start_boundary_line
      && newer.start_atom <= old.start_atom && newer.end_atom >= old.end_atom
      && (newer.end_atom <> old.end_atom || newer.last_atom_digest = old.last_atom_digest)
  in
  let official = match Source.official_range_id original, Source.official_range_id actual with
    | None, (None | Some _) -> true
    | Some _, None -> false
    | Some (old : Current.official_range_id), Some (newer : Current.official_range_id) ->
      old.receipt_scope = newer.receipt_scope && newer.after_boundary_line <= old.after_boundary_line
      && List.for_all (fun turn -> List.mem turn newer.turns) old.turns
  in
  atom && official
  && observations_cover (Source.input original).counterpart_observations
       (Source.input actual).counterpart_observations

(* Inventory validation has checked the original host final, Gate and commit
   marker. Finished was recorded after the receipts and source positions settled;
   the current range receipt may now belong to a later completed input. *)
let completed_covers ~original ((record : Retained.retained), candidate) =
  match Progress.phase record.progress with
  | Finished _ ->
    source_covers original (Request.source candidate)
    && Result.is_ok (Runtime.require_counterpart_template (Request.preparation candidate))
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
  | Commit_unknown _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false

let counterpart_only source =
  let input = Source.input source in
  input.messages = [] && input.tool_observations = [] && input.counterpart_observations <> []

(* Pin the witness even when its refusal is ready to move now. Settlement moves
   records one at a time, so the refusal must leave the live inventory before
   the finished execution it may still need is allowed to leave it. *)
let preserves_completed ~settled ~(record:Retained.retained) ~request =
  match Progress.phase record.progress with
  | Finished _ ->
    List.exists (fun ((refused : Retained.retained), original) ->
      match Progress.phase refused.progress with
      | Rejected {stage=Progress.Execution;_} ->
        let source = Request.source original in
        counterpart_only source && completed_covers ~original:source (record, request)
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
      | Commit_unknown _ | Finished _ | Conflicted _ | Rejected {stage=Progress.Before_dispatch;_}
      | Subdividing _ | Subdivided _ -> false) settled
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
  | Commit_unknown _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false

let retained_stop ~store ~completed ~(record:Retained.retained) ~request =
  let source=Request.source request in
  match Progress.phase record.progress with
  | Rejected {stage=Progress.Execution;evidence} ->
    if not (counterpart_only source) then Ok None else
    let* exact=Request.request request in
    let* schema=Option.to_result ~none:"Original history refusal lacks its schema" exact.schema in
    let* retained=Exact.retained_final_of_json ~schema evidence in
    let final=Exact.delivered retained in
    (match final with
     | Exact.Call_final (Input_refused (Input_capacity | Context_overflow | Request_body_refused)) ->
       (* Unlike a display report, an unreadable proof cannot release this
          original for another request. Whole-inventory validation precedes us. *)
       let* evidence=io (fun () -> Request.refusal_evidence ~store request final) in
       let report=Runtime.not_committed_of_failure ~detail:(detail final) evidence in
       (match Consumer.refused_original source [report] with
        | Error (Consumer.Counterpart_input_capacity_refused {counterpart_digest;_} as refusal) ->
          let* committed=io (fun () ->
            let* past=Keeper_librarian_refusal_frontier.past_original ~counterpart_digest request in
            Ok (past && List.exists (completed_covers ~original:source) completed)) in
          Ok (if committed then None else Some {request_id=record.request_id;
            destination=Request.destination request;refusal})
        | Error ((Consumer.Keeper_meta_absent
                 | Original_publication_blocked _ | Source_capture_failed _
                 | Keeper_meta_unreadable _ | Boundary_log_unreadable _
                 | Progress_unreadable _ | Checkpoint_unreadable _
                 | Position_in_other_trace _ | Position_not_in_history _
                 | Range_stopped _ | Range_end_boundary_missing _
                 | Progress_boundary_missing _ | Memory_snapshot_unreadable _
                 | Counterpart_interval_non_monotone _
                 | Counterpart_observations_unreadable _ | Progress_write_failed _
                 | Official_progress_unreadable _ | Official_progress_write_failed _
                 | Official_progress_boundary_missing _
                 | Committed_official_range_mismatch | Official_range_stopped _
                 | Fragment_store_unreadable _ | Fragment_line_unreadable _) as refusal) ->
          Ok (Some {request_id=record.request_id;destination=Request.destination request;refusal})
        | Ok _ -> Ok None)
     | Call_final (Answered _ | Invalid_output _ | Input_refused Invalid_request | Output_limit_reached _)
     | Outcome_unknown | Not_allowed _ | Request_id_reused -> Ok None)
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Rejected {stage=Progress.Before_dispatch;_}
  | Subdividing _ | Subdivided _ -> Ok None
let request_id stop=stop.request_id
let blocks_destination stops current =
  List.find_map (fun stop -> if Edge.same_destination current stop.destination
    then Some stop.refusal else None) stops
let blocked ~config ~reserved = function
  | [] -> None
  | (first::_ as stops) ->
    match Edge.with_destination ~config ~reserved (fun current -> Ok (blocks_destination stops current)) with
    | Ok refusal -> refusal
    | Error _ -> Some first.refusal

module For_testing = struct
  let observations_cover = observations_cover
end
