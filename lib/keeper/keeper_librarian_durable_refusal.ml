module Request = Keeper_librarian_durable_request
module Retained = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Runtime = Keeper_librarian_runtime
module Consumer = Keeper_librarian_durable_consumer
module Source = Keeper_librarian_durable_capture
module Sources = Keeper_librarian_input_sources
module Edge = Keeper_librarian_durable_edge
module Current = Keeper_memory_os_current
open Result.Syntax
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f
type t = {request_id:string;destination:Request.destination;refusal:Consumer.error;
  original:Retained.retained*Request.t}
type retained = {record:Retained.retained;request:Request.t;
  selection:Sources.counterpart_selection Lazy.Mutexed.t}
type inventory = retained list
let selection request = Lazy.Mutexed.from_fun (fun () ->
  Sources.select_counterparts (Source.counterparts (Request.source request)))
let inventory settled =
  let module Ids=Set.Make(String) in
  let* _=List.fold_left (fun result ((record:Retained.retained),request) ->
    let* seen=result in
    if Ids.mem record.request_id seen then Error "Duplicate original history request ID in inventory"
    else let+ ()=Request.confirm_record request record in Ids.add record.request_id seen)
    (Ok Ids.empty) settled in
  Ok (List.map (fun (record,request) -> {record;request;selection=selection request}) settled)
let member inventory ~record ~request =
  List.find_opt (fun item -> item.record == record && item.request == request) inventory
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
let source_covers ~original ~original_selection ~actual ~actual_selection =
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
  && Sources.counterpart_selection_covers ~original:(Lazy.Mutexed.force original_selection)
       ~witness:(Lazy.Mutexed.force actual_selection)

(* Inventory validation has checked the original host final, Gate and commit
   marker. Finished was recorded after the receipts and source positions settled;
   the current range receipt may now belong to a later completed input. *)
let completed_covers ~original ~original_selection {record;request=candidate;selection} =
  match Progress.phase record.progress with
  | Finished _ ->
    Yojson.Safe.equal (Request.owner_to_json (Request.physical_owner original))
      (Request.owner_to_json (Request.physical_owner candidate))
    && Result.is_ok (Runtime.require_counterpart_template (Request.preparation candidate))
    && source_covers ~original:(Request.source original) ~original_selection
         ~actual:(Request.source candidate) ~actual_selection:selection
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
  | Commit_unknown _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false

let counterpart_only source =
  let input = Source.input source in
  input.messages = [] && input.tool_observations = [] && input.counterpart_observations <> []

(* Pin possible partial witnesses too. Settlement moves records one at a time,
   so a refusal must leave the live inventory before any finished execution
   with overlapping source identity can leave. This does not prove coverage. *)
let preserves_completed ~settled ~(record:Retained.retained) ~request =
  match member settled ~record ~request with
  | None -> true
  | Some candidate ->
    (match Progress.phase record.progress with
     | Finished _ ->
       List.exists (fun original ->
         match Progress.phase original.record.progress with
         | Rejected {stage=Progress.Execution;_} ->
           let source = Request.source original.request in
           counterpart_only source
           && Yojson.Safe.equal (Request.owner_to_json (Request.physical_owner original.request))
                (Request.owner_to_json (Request.physical_owner candidate.request))
           && Sources.counterpart_selection_may_overlap
                ~original:(Lazy.Mutexed.force original.selection)
                ~candidate:(Lazy.Mutexed.force candidate.selection)
         | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
         | Commit_unknown _ | Finished _ | Conflicted _ | Rejected {stage=Progress.Before_dispatch;_}
         | Subdividing _ | Subdivided _ -> false) settled
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
     | Commit_unknown _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false)

let retained_stop ~store ~completed ~(record:Retained.retained) ~request =
  let* original=Option.to_result ~none:"Refused original is absent from the validated inventory"
    (member completed ~record ~request) in
  let source=Request.source request in
  match Progress.phase record.progress with
  | Rejected {stage=Progress.Execution;evidence} ->
    if not (counterpart_only source) || Option.is_some (Progress.settlement record.progress) then Ok None else
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
            if not past then Ok false else
            Ok (List.exists (completed_covers ~original:request ~original_selection:original.selection) completed)) in
          Ok (if committed then None else Some {request_id=record.request_id;
            destination=Request.destination request;refusal;original=(record,request)})
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
          Ok (Some {request_id=record.request_id;destination=Request.destination request;refusal;original=(record,request)})
        | Ok _ -> Ok None)
     | Call_final (Answered _ | Invalid_output _ | Input_refused Invalid_request | Output_limit_reached _)
     | Outcome_unknown | Not_allowed _ | Request_id_reused -> Ok None)
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Rejected {stage=Progress.Before_dispatch;_}
  | Subdividing _ | Subdivided _ -> Ok None
let request_id stop=stop.request_id
let original stop=stop.original
(* The coordinates a settled refusal keeps: what was abandoned and what the
   settlement applied, so the record alone says why this range was never read. *)
let diagnosis stop = match stop.refusal with
  | Consumer.Counterpart_input_capacity_refused
      {atom_range;official_range;counterpart_digest;observation_count;observation_bytes;reports;_} ->
    let ((record:Retained.retained),_)=stop.original in
    let optional encode=Option.fold ~none:`Null ~some:encode in
    Some (`Assoc ["version",`Int 1;"kind",`String "librarian-capacity-refusal-settled";
      "refused_request_id",`String record.request_id;"refused_request_digest",`String record.request_digest;
      "counterpart_digest",`String counterpart_digest;
      "observation_count",`Int observation_count;"observation_bytes",`Int observation_bytes;
      "atom",optional Current.durable_range_id_to_json atom_range;
      "official",optional Current.official_range_id_to_json official_range;
      (* Each read position moves only when the refused range has that part
         (Commit.atom_target / official_target are Option.map over the range). *)
      "applied",`List ([`String "memory range receipts, no claims";`String "external ACK through the refused frontier"]
        @ (if Option.is_some atom_range then [`String "atom read position to the refused range end"] else [])
        @ (if Option.is_some official_range then [`String "official read position to the refused range end"] else []));
      "reports",`List (List.map (fun (report:Runtime.not_committed) -> `String report.detail) reports)])
  | Consumer.Keeper_meta_absent | Original_publication_blocked _ | Source_capture_failed _
  | Keeper_meta_unreadable _ | Boundary_log_unreadable _ | Progress_unreadable _
  | Checkpoint_unreadable _ | Position_in_other_trace _ | Position_not_in_history _
  | Range_stopped _ | Range_end_boundary_missing _ | Progress_boundary_missing _
  | Memory_snapshot_unreadable _ | Counterpart_interval_non_monotone _
  | Counterpart_observations_unreadable _ | Progress_write_failed _
  | Official_progress_unreadable _ | Official_progress_write_failed _
  | Official_progress_boundary_missing _ | Committed_official_range_mismatch
  | Official_range_stopped _ | Fragment_store_unreadable _ | Fragment_line_unreadable _ -> None
let blocks_destination stops current =
  List.find_map (fun stop -> if Edge.same_destination current stop.destination
    then Some stop.refusal else None) stops
let blocked ~config ~reserved = function
  | [] -> None
  | (first::_ as stops) ->
    match Edge.with_destination ~config ~reserved (fun current -> Ok (blocks_destination stops current)) with
    | Ok refusal -> refusal
    | Error _ -> Some first.refusal
