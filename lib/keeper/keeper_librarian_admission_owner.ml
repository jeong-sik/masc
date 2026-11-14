module Capture = Keeper_librarian_admission_capture
module Parts = Keeper_librarian_admission_parts
module Closure = Keeper_librarian_admission_closure
module Dispatch = Keeper_librarian_admission_dispatch
module Commit = Keeper_librarian_admission_commit
module Gate_journal = Keeper_librarian_admission_gate
module Gate = Keeper_librarian_absorb_gate
module Owner = Lane_addon_tool_request_owner
module Destination = Lane_addon_captured_destination
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Runtime = Lane_addon_runtime
module Current = Keeper_memory_os_current
module Queue = Keeper_memory_admission_queue
open Result.Syntax
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f
let owned result = Result.map_error Owner.error_to_string result
let require value detail = if value then Ok () else Error detail
let runtime_error = function
  | Runtime.Unavailable detail | Outcome_unknown detail -> detail
  | Host_refusal refusal -> match refusal with
    | Lane_addon_call_context.Rejected detail | Unavailable detail
    | Activity_disabled detail | Activity_unobserved detail -> detail
let reserved = Keeper_librarian_addon.reserved
let resolve ~config ~reserved =
  Keeper_librarian_addon.resolve ~config ~reserved Keeper_librarian_addon.Admission
  |> Result.map_error Keeper_librarian_addon.unavailable_to_string
(* Only genuine absence means off. Starting, failed and conflicting workers
   retain their actual cause and cannot turn pending originals into off. *)
let unattached ~config ~reserved =
  match Keeper_librarian_addon.resolve ~config ~reserved Keeper_librarian_addon.Admission with
  | Error Keeper_librarian_addon.Unattached -> true
  | Ok _ | Error (Unready _ | Export_conflict _ | Wrong_package _ | Manual_installation) -> false
let with_destination ~config ~reserved publish =
  let* export=resolve ~config ~reserved in
  Runtime.with_tool_request_destination ~config ~reserved ~export
    ~access:Lane_addon_sources.Operator_configuration ~publish:(fun actual ->
      let actual=Destination.of_runtime actual in
      if actual.package_id<>Capture.package_id || actual.tool<>Capture.tool
      then Error (Runtime.Host_refusal (Lane_addon_call_context.Rejected "Librarian requires its configured package/tool"))
      else match publish actual with Ok value -> Ok value | Error detail -> Error (Runtime.Unavailable detail))
  |> Result.map_error runtime_error
let admit ~config ~reserved ~destination:expected ~publish =
  with_destination ~config ~reserved (fun actual ->
    let* ()=require (Destination.same_semantic actual expected) "Original Librarian semantic configuration changed" in
    io publish)
let check_owner owner = io (fun () ->
  let* actual=Capture.observe_owner ~base_path:(Capture.base_path owner)
    ~keepers_dir:(Capture.keepers_dir owner) ~keeper_id:(Capture.keeper_id owner) in
  Capture.owner_matches_json actual (Capture.owner_to_json owner))
let fresh_authority ~config ~reserved owner capture =
  let* ()=check_owner owner in
  admit ~config ~reserved ~destination:(Capture.destination capture) ~publish:(fun () -> Ok ())

type outcome = Disabled | Idle | Recheck_new_input | Settled of {has_more:bool}
  | Pending of string | Awaiting_worker of Keeper_librarian_pending.worker
  | Addon_unattached of {pending:int} | Unavailable of string

type original = {capture:Capture.t;record:Owner.retained}
type inventory = {parts:Parts.inventory;executions:original list}
(* What a queue pass holds before it evaluates a part. [discover] reads and
   validates every record of the Keeper, so the pass reads again only after
   it may have written since its last read. *)
type held = Read_after_last_write of inventory | Written_since_read
let discover ~store ~owner =
  let* parts=Parts.discover ~store ~owner in
  let* records=owned (Owner.load_scope ~store ~scope:(Capture.scope owner)) in
  let* executions=List.fold_left (fun result record ->
    let* originals=result in
    let* capture=Capture.restore ~owner ~load_parent:(Parts.load_parent parts) record in
    let* ()=Commit.validate ~store ~owner ~capture ~record in
    let* ()=require (not (List.exists (fun original ->
      Capture.parent_part_id original.capture=Capture.parent_part_id capture) originals))
      "A Librarian part has multiple original executions" in
    Ok ({capture;record}::originals)) (Ok []) records in
  let* gates=owned (Owner.load_scope ~store ~scope:(Gate_journal.scope owner)) in
  let* ()=List.fold_left (fun result gate ->
    let* ()=result in
    let* id=Gate_journal.parent_execution_id gate in
    let* original=List.find_opt (fun original -> original.record.request_id=id) executions
      |> Option.to_result ~none:"Original gate has no discovered execution" in
    Gate_journal.validate ~store ~owner ~capture:original.capture ~record:gate) (Ok ()) gates in
  let* ()=List.fold_left (fun result original ->
    let* ()=result in
    Gate_journal.validate_chain ~store ~owner ~capture:original.capture) (Ok ()) executions in
  Ok {parts;executions}
let for_part inventory part=List.find_opt (fun original ->
  Capture.parent_part_id original.capture=Parts.part_id part) inventory.executions
let last_gate ~store ~owner original =
  io (fun () -> Gate_journal.latest ~store ~owner ~capture:original.capture)

let original_answer ~store original =
  let* judgment=match Progress.phase original.record.progress with
    | Progress.Judged value -> Ok value
    | Committing commit | Commit_unknown (commit,_) | Finished commit -> Ok commit.judgment
    | Captured | Admission_wait _ | Dispatch_pending _ | Conflicted _ | Rejected _
    | Subdividing _ | Subdivided _ -> Error "Original execution has no answered proposal" in
  let* final=io (fun () -> Capture.decode_final ~store original.capture judgment) in
  match final with
  | Exact.Call_final (Answered {output;_}) -> Ok (Exact.checked_json output)
  | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
  | Outcome_unknown | Not_allowed _ | Request_id_reused -> Error "Original judgment is not an answered proposal"
let new_capture ~config ~reserved ~owner part =
  let keepers_dir=Capture.keepers_dir owner and keeper_name=Capture.keeper_id owner in
  let* ()=check_owner owner in
  let* keeper_id,meta=io (fun () ->
    match Keeper_meta_store.read_effective_meta_presence_named config keeper_name with
    | Error detail | Ok (_,Keeper_meta_store.Meta_not_current detail) -> Error detail
    | Ok (_,Meta_absent) -> Error "Keeper metadata is absent"
    | Ok (keeper_id,Meta_present meta) -> Ok (keeper_id,meta)) in
  let* snapshot=io (fun () -> Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name) in
  let expected_revision=Option.map (fun (value : Current.t) -> value.revision) snapshot in
  let input : Keeper_librarian.input={keeper_id;keeper_instructions=meta.instructions;
    turn_ref=Ids.Turn_ref.make ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ~absolute_turn:meta.runtime.usage.total_turns;
    current=Option.map (fun (value : Current.t) -> ({Keeper_librarian.facts=value.facts} : Keeper_librarian.current_selection)) snapshot;
    historical_task_contexts=[];goal_context=io (fun () -> Keeper_librarian_input_sources.goal_context_for_task ~config meta.current_task_id);
    working_context=Keeper_librarian_context.empty;messages=[];tool_observations=[];counterpart_observations=[]} in
  let* retirement=io (fun () -> match Current.read_retirement_context ~keepers_dir ~keeper_id:keeper_name
    ~expected_revision ~current_facts:(match input.current with None -> [] | Some current -> current.facts) with
    | Current.Retirement_source_changed -> Error "Memory changed before original admission capture"
    | Retirement_source_unavailable detail -> Error detail
    | Retirement_archive (Ok archive) -> Ok (Keeper_memory_admission_judgment.Available archive)
    | Retirement_archive (Error detail) -> Ok (Keeper_memory_admission_judgment.Unavailable detail)) in
  let* source_lines=io (fun () ->
    Keeper_memory_source_current.read_budget_lines ~keepers_dir ~keeper_id:keeper_name) in
  let* preparation=Keeper_librarian_runtime.prepare_admission ~batch:(Parts.batch part) ~retirement
    ~source_lines input in
  let now=Time_compat.now () in
  let* export=resolve ~config ~reserved in
  let request_id=Capture.fresh_request_id owner in
  let* capture=Runtime.capture_tool_request_owner ~config ~reserved ~export
    ~access:Lane_addon_sources.Operator_configuration ~scope:(Capture.scope owner) ~request_id
    ~capture:(fun actual ->
      let destination=Destination.of_runtime actual in
      let* ()=require (Destination.same_semantic destination (Parts.destination part))
        "Original candidate part belongs to another semantic configuration" in
      let* capture=Capture.create ~request_id ~parent_part_id:(Parts.part_id part) ~owner ~destination
        ~batch:(Parts.batch part) ~input ~expected_revision ~now ~retirement ~preparation in
      Ok (capture,Capture.to_json capture,`Null)) |> Result.map_error runtime_error in
  let* record=io (fun () -> owned (Owner.load ~store:(Lane_addon_store.of_config config) ~scope:(Capture.scope owner) ~request_id)) in
  let* record=Option.to_result ~none:"Original captured admission disappeared" record in
  Ok {capture;record}
let call ~config ~reserved ~expected ~(original : Owner.retained) ~arguments =
  match resolve ~config ~reserved with
  | Error detail -> Error (Lane_addon_submit_once.Not_sent (Dispatch.Unavailable detail))
  | Ok export -> Runtime.call_captured_tool_request ~config ~reserved ~export
    ~access:Lane_addon_sources.Operator_configuration ~installation_id:expected.Destination.installation_id
    ~package_id:expected.package_id ~tool:expected.tool ~configuration_revision:expected.configuration_revision
    ~original ~arguments |> Result.map_error Lane_addon_submit_once.call_error_of_runtime

type part_result =
  | Terminal of Parts.terminal_source * bool
  | Children of Parts.part * Parts.part
  | Waiting of string
  | Worker_wait of Keeper_librarian_pending.worker
  | Addon_off
  | Reprepared
let source original part = Parts.Original_execution {
  part_id=Parts.part_id part;execution_id=original.record.request_id}
let local_admit actual ~destination:expected ~publish =
  let* ()=require (Destination.same_semantic actual expected) "Original Librarian semantic configuration changed" in
  publish ()
let partition ~store ~config ~reserved ~owner part evidence =
  let id ()=Capture.fresh_request_id owner in
  with_destination ~config ~reserved (fun actual ->
    io (fun () -> Parts.partition ~store ~owner
      ~parent:part ~evidence ~partition_id:(id ()) ~left_id:(id ()) ~right_id:(id ())
      ~admit:(local_admit actual)))
  |> Result.map (fun (left,right) -> Children (left,right))
(* The retained refusal of an execution the execution stage rejected. A
   subdivision names a successor, so it is not read here; admission writes
   none. Other phases carry no refusal. *)
let execution_refusal original =
  match Progress.phase original.record.Owner.progress with
  | Progress.Rejected {stage=Progress.Execution;evidence} ->
    let* exact=Capture.request original.capture in
    let* schema=Option.to_result ~none:"Original admission schema is absent" exact.schema in
    let+ retained=Exact.retained_final_of_json ~schema evidence in Some retained
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Rejected {stage=Progress.Before_dispatch;_}
  | Subdividing _ | Subdivided _ -> Ok None
let refusal_label = function
  | Exact.Retained_unknown Exact.Interrupted -> "outcome_unknown interrupted"
  | Retained_unknown Exact.Cut -> "outcome_unknown cut"
  | Retained_unknown Exact.Raised -> "outcome_unknown raised"
  | Retained_call (Answered _) -> "answered"
  | Retained_call (Invalid_output _) -> "invalid_output"
  | Retained_call (Input_refused _) -> "input_refused"
  | Retained_call (Output_limit_reached _) -> "output_limit_reached"
  | Retained_not_allowed _ -> "not_allowed"
  | Retained_request_id_reused -> "request_id_reused"
let size_refused ~store ~config ~reserved ~owner ~inventory ~refusal part original =
  match io (fun () -> Parts.execution_size_evidence ~store ~owner ~inventory:inventory.parts
    ~parent:part ~execution_id:original.record.request_id) with
  | Error _ ->
    let cause=Option.fold ~none:"" ~some:(fun retained -> ": " ^ refusal_label retained) refusal in
    Ok (Waiting ("Original host execution has no exclusive input-capacity proof" ^ cause))
  | Ok evidence -> match Queue.split (Parts.batch part) with
    | None -> Ok (Terminal (source original part,false))
    | Some _ -> partition ~store ~config ~reserved ~owner part evidence
let gate_result ~store ~config ~reserved ~owner ~inventory part original proposal accepted =
  let capture=original.capture in
  let* prior=last_gate ~store ~owner original in
  let* original,record=match prior with
    | None ->
      let authority=Gate.resolve ~keeper_id:(Capture.keeper_id owner) in
      let request_id=Capture.fresh_request_id owner in
      let* prepared=Commit.begin_gate ~store ~owner ~capture ~record:original.record ~gate_root_id:request_id ~authority in
      (match prepared with
       | Commit.Reload_original -> Error "Reload the original gate disposition intent before proceeding"
       | Prepared _ ->
         let* parent=io (fun () -> Gate_journal.recover_root ~store ~owner ~capture) in
         let* record=io (fun () -> Gate_journal.latest ~store ~owner ~capture) in
         let* record=Option.to_result ~none:"Original gate root publication disappeared" record in
         Ok ({original with record=parent},record))
    | Some record -> Ok (original,record) in
  let live=match fresh_authority ~config ~reserved owner capture with
    | Ok () -> Some (Gate.resolve ~keeper_id:(Capture.keeper_id owner))
    | Error _ -> None in
  let resume record=Gate_journal.resume ~request_clock:Eio_context.get_clock
    ~store ~owner ~capture ~record ~live_authority:live
    ~before_dispatch:(fun () -> fresh_authority ~config ~reserved owner capture) in
  let* completed=resume record in
  let apply gate record =
    match Gate.failure_detail ~absorbed:accepted.Keeper_librarian_runtime.selection.absorbed gate with
    | None ->
      let* settled=Commit.settle ~store ~owner ~capture ~record:original.record ~gate_request_id:record.Owner.request_id in
      (match settled with
       | Commit.Committed _ -> Ok (Terminal (source original part,true))
       | Pending detail -> Ok (Waiting detail))
    | Some detail -> Ok (Waiting detail) in
  match completed with
  | Gate_journal.Pending _ -> Ok (Waiting "Original absorption evaluation remains pending")
  | Complete (gate,record) ->
    (* A completed failed gate is not an unknown dispatch. A later real wake
       may retain one new attempt on the same immutable parent/proposal. *)
    let retry authority =
       let* next=io (fun () -> Gate_journal.retain ~store ~owner ~capture ~parent:original.record ~proposal
         ~request_id:(Capture.fresh_request_id owner) ~authority ~predecessor:(Some record.request_id)) in
       let* retried=resume next in
       (match retried with
        | Pending _ -> Ok (Waiting "Original absorption retry awaits its first unstarted question")
        | Complete (gate,next) -> apply gate next) in
    (match prior with
     | None -> apply gate record
     | Some _ ->
       match Gate.failure_detail ~absorbed:accepted.selection.absorbed gate with
       | None -> apply gate record
       | Some _ ->
         match live with None -> apply gate record | Some authority -> retry authority)
let answered ~store ~config ~reserved ~owner ~inventory part original =
  let* proposal=original_answer ~store original in
  let* parsed=Capture.validate_proposal original.capture proposal in
  match parsed with
  | Keeper_librarian_runtime.Deferred -> Ok (Terminal (source original part,false))
  | Accepted accepted -> gate_result ~store ~config ~reserved ~owner ~inventory part original proposal accepted
(* RFC-0500. The process that started this execution's attempt stopped
   before it ended, so no judgment reached the host. The execution settles
   and the walk evaluates its part again, which captures a fresh execution.
   No other record names it. A gate intent follows only [Judged], which a
   refused execution never passed. A partition names only an execution with
   a size proof, and the forest check of [discover] refuses any other.
   An interrupted execution repeats only if the server stops again: one that
   this process cuts is [Cut] and keeps blocking. *)
let settle_interrupted ~store ~owner part original =
  let* date=Capture.minted_on original.record.request_id in
  let* ()=io (fun () -> Owner.settle ~store ~date (Owner.listed original.record))
    |> Result.map_error Owner.settle_error_to_string in
  Log.Keeper.info ~keeper_name:(Capture.keeper_id owner)
    "Librarian explicit admission settled interrupted execution %s; part %s is prepared again"
    original.record.request_id (Parts.part_id part);
  Ok Reprepared
let evaluate ~store ~config ~reserved ~owner ~inventory part =
  let existing=for_part inventory part in
  (* No destination can capture a fresh original while Off. An existing
     original still takes submit-once's actual wait/terminal observation, even
     before admission; Off must not erase its identity or retained progress. *)
  if Option.is_none existing && unattached ~config ~reserved then Ok Addon_off else
  let* original=match existing with
    | Some original -> Ok original
    | None -> new_capture ~config ~reserved ~owner part in
  let* ()=check_owner owner in
  let* exact=Capture.request original.capture in
  let* schema=Option.to_result ~none:"Original admission schema is absent" exact.schema in
  let* state=Dispatch.resume ~store ~config ~reserved ~capture:original.capture ~destination:(Capture.destination original.capture)
    ~original:original.record ~exact ~schema
    ~validate_answer:(fun proposal -> Capture.validate_proposal original.capture proposal |> Result.map (fun _ -> ()))
    ~call:(call ~config ~reserved) |> Result.map_error Dispatch.error_to_string in
  match state with
  | Dispatch.Pending (wait, record) ->
    Ok (Worker_wait (Keeper_librarian_pending.of_worker_wait
      ~installation_id:record.installation_id ~request_id:record.request_id wait))
  | Refused (_,record) ->
    let original={original with record} in
    let* refusal=execution_refusal original in
    (match refusal with
     | Some (Exact.Retained_unknown Exact.Interrupted) -> settle_interrupted ~store ~owner part original
     | Some (Exact.Retained_unknown (Exact.Cut | Exact.Raised)
         | Retained_call (Answered _ | Invalid_output _ | Input_refused _ | Output_limit_reached _)
         | Retained_not_allowed _ | Retained_request_id_reused)
     | None -> size_refused ~store ~config ~reserved ~owner ~inventory ~refusal part original)
  | Answered (_,record) | Commit_pending record ->
    answered ~store ~config ~reserved ~owner ~inventory part {original with record}
  | Settled record ->
    (match Progress.phase record.progress with
     | Progress.Finished _ -> answered ~store ~config ~reserved ~owner ~inventory part {original with record}
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
       Ok (Waiting "Original admission is terminal without a proved domain commit"))
let frontier ~store ~owner inventory =
  let rec all accumulated = function
    | [] -> Ok (Some (List.rev accumulated))
    | part::rest ->
      match for_part inventory part with
      | None -> Ok None
      | Some original ->
        let continue terminal=all (terminal::accumulated) rest in
        (match Progress.phase original.record.progress with
         | Progress.Finished _ -> continue (source original part)
         | Judged _ | Committing _ ->
           let* proposal=original_answer ~store original in
           let* parsed=Capture.validate_proposal original.capture proposal in
           (match parsed with
            | Keeper_librarian_runtime.Deferred -> continue (source original part)
            | Accepted _ -> Ok None)
         | Rejected _ ->
           (match io (fun () -> Parts.execution_size_evidence ~store ~owner ~inventory:inventory.parts
             ~parent:part ~execution_id:original.record.request_id),Queue.split (Parts.batch part) with
            | Ok _,None -> continue (source original part)
            | (Ok _ | Error _),(None | Some _) -> Ok None)
         (* Only a destination-absent conflict can end an admission here, and
            discovery validated it. The frontier hands its candidates to a
            replacement root (#46372), whose proof requires that they are
            uncommitted ([Parts.terminal_witness]). *)
         | Conflicted _ -> continue (source original part)
         | Captured | Admission_wait _ | Dispatch_pending _ | Commit_unknown _
         | Subdividing _ | Subdivided _ -> Ok None) in
  all [] (Parts.runnable inventory.parts)
let retain_root ~store ~config ~reserved ~owner ?supersession batch =
  with_destination ~config ~reserved (fun destination ->
    io (fun () -> Parts.retain_root ~store ~owner
      ?supersession ~part_id:(Capture.fresh_request_id owner) ~destination ~batch
      ~admit:(local_admit destination) ()))
module Candidate_ids = Set.Make (struct
  type t = Current.explicit_candidate_id
  let compare=Stdlib.compare
end)
module Candidate_sequences = Set.Make (Int)
module Candidate_requests = Set.Make (String)
let committed_and_acknowledged ~owner ids =
  let keepers_dir=Capture.keepers_dir owner and keeper_id=Capture.keeper_id owner in
  let* actual=Capture.observe_owner ~base_path:(Capture.base_path owner) ~keepers_dir ~keeper_id in
  let* ()=Capture.owner_matches_json actual (Capture.owner_to_json owner) in
  let* generation=Queue.read_generation ~keepers_dir ~keeper_id in
  match generation,ids with
  | None,_ | Some _,[] -> Ok false
  | Some generation,_::_ ->
    let* ()=require (List.for_all (fun (id:Current.explicit_candidate_id) -> id.queue_generation=generation) ids)
      "Admission closure queue generation changed" in
    let* receipts=Current.committed_explicit_candidates ~keepers_dir ~keeper_id ~queue_generation:generation in
    let receipts=Candidate_ids.of_list receipts in
    let* pending=Queue.read_pending ~keepers_dir ~keeper_id in
    let pending=Option.fold ~none:[] ~some:Queue.candidate_ids pending in
    let sequences=Candidate_sequences.of_list (List.map (fun (id:Current.explicit_candidate_id) -> id.sequence) ids) in
    let requests=Candidate_requests.of_list (List.map (fun (id:Current.explicit_candidate_id) -> id.request_id) ids) in
    Ok (List.for_all (fun id -> Candidate_ids.mem id receipts) ids
      && not (List.exists (fun (row:Current.explicit_candidate_id) ->
        row.queue_generation=generation && (Candidate_sequences.mem row.sequence sequences
          || Candidate_requests.mem row.request_id requests)) pending))
let completed_forest ~store ~owner inventory =
  match Parts.completion_candidates inventory.parts with
  | None -> Ok None
  | Some ids ->
    let leaves=Parts.runnable inventory.parts in
    let finished part=match for_part inventory part with
      | None -> false
      | Some original -> match Progress.phase original.record.progress with
        | Progress.Finished _ -> true
        | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
        | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false in
    if not (List.for_all finished leaves) then Ok None else
    (* Superseded semantic gaps, superseded destination-absent conflicts and
       actual partition-size refusals may be historical ancestors. Unknown/cut
       or ordinary failed work never closes. *)
    let* terminal=List.fold_left (fun result original ->
      let* terminal=result in if not terminal then Ok false else
      match Progress.phase original.record.progress with
      | Progress.Finished _ -> Ok true
      | Judged _ ->
        let* proposal=original_answer ~store original in
        let+ proposal=Capture.validate_proposal original.capture proposal in
        (match proposal with Keeper_librarian_runtime.Deferred -> true | Accepted _ -> false)
      | Rejected _ ->
        let* parent=Parts.find inventory.parts ~part_id:(Capture.parent_part_id original.capture) in
        Ok (Result.is_ok (Parts.execution_size_evidence ~store ~owner ~inventory:inventory.parts
          ~parent ~execution_id:original.record.request_id))
      (* Every runnable leaf is Finished here and a part has one execution,
         so this conflict is on no runnable leaf: a replacement root took its
         candidates over. The receipt and ACK check below covers every one of
         them. *)
      | Conflicted _ -> Ok true
      | Captured | Admission_wait _ | Dispatch_pending _ | Committing _ | Commit_unknown _
      | Subdividing _ | Subdivided _ -> Ok false) (Ok true) inventory.executions in
    if not terminal then Ok None else
    let+ complete=committed_and_acknowledged ~owner ids in if complete then Some ids else None
let closure_ports ~store =
  let read ~scope ~request_id=Owner.load ~store ~scope ~request_id |> owned in
  let read_scope ~scope=Owner.load_scope ~store ~scope |> owned in
  let reader=Owner.Published_reader.create ~read_body:(fun ~scope ~request_digest ->
    Lane_addon_store.load_tool_request_body store ~scope ~request_digest) in
  let read_body=Owner.Published_reader.request reader in
  let read_archive ~scope ~date ~request_id=Owner.load_settled ~store ~scope ~date ~request_id |> owned in
  read,read_scope,read_body,read_archive
let recover_closure ~store ~owner ~after_settle =
  let read,read_scope,read_body,read_archive=closure_ports ~store in
  let* view=Closure.project ~owner ~read ~read_scope ~read_body ~read_archive in
  match view.closure with
  | None -> Ok ()
  | Some closure ->
    let* complete=committed_and_acknowledged ~owner (Closure.candidates closure) in
    let* ()=require complete "Admission closure lacks complete current candidate receipts or queue ACK" in
    let* ()=Keeper_librarian_store_preflight.validator () ~read ~read_scope ~read_body ~read_archive
      ~read_fence:(Lane_addon_store.load_history_fence store)
      ~read_resolution:(Lane_addon_store.load_history_resolution store)
      (Closure.record closure) in
    let* closure=match Closure.stage closure with
      | Closure.Captured ->
        let* inventory=discover ~store ~owner in
        let* current=completed_forest ~store ~owner inventory in
        let* ()=require (current=Some (Closure.candidates closure))
          "Captured admission closure no longer has the same complete normal frontier" in
        Closure.intend ~store closure
      | Closing | Closed -> Ok closure in
    (* Repeat even an already archived member: a record move can precede body
       removal. The exact metadata was checked above; settle completes both
       directory-sync and body-cleanup obligations before the anchor closes. *)
    let* ()=List.fold_left (fun result member -> let* ()=result in
      let record=Closure.member_record member in
      let* ()=Owner.settle ~store ~date:(Closure.date closure) record
        |> Result.map_error Owner.settle_error_to_string in
      after_settle record) (Ok ()) (Closure.members closure) in
    let* closure=Closure.confirm ~store closure in
    let* _confirmed=Closure.project ~owner ~read ~read_scope ~read_body ~read_archive in
    Owner.settle ~store ~date:(Closure.date closure) (Owner.listed (Closure.record closure))
      |> Result.map_error Owner.settle_error_to_string
let close_completed_forest ~store ~owner ~after_settle inventory =
  let* eligible=completed_forest ~store ~owner inventory in
  match eligible with
  | None -> Ok false
  | Some candidates ->
    let* originals=List.fold_left (fun result (kind,scope) -> let* originals=result in
      let+ records=match kind with
        | Closure.Execution -> Ok (List.map (fun original -> original.record) inventory.executions)
        | Part | Partition | Gate -> Owner.load_scope ~store ~scope |> owned in
      originals @ List.map (fun record -> kind,record) records) (Ok [])
      [Closure.Part,Parts.scope owner;Partition,Parts.partition_scope owner;
       Execution,Capture.scope owner;Gate,Gate_journal.scope owner] in
    let* _closure=Closure.retain ~store ~owner ~request_id:(Capture.fresh_request_id owner)
      ~candidates ~originals in
    let+ ()=recover_closure ~store ~owner ~after_settle in true
let run_queue ~after_settle ~base_path ~keeper_name =
  let config=Workspace.default_config base_path in
  let reserved=reserved () in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let store=Lane_addon_store.of_config config in
  let read ()=io (fun () -> Queue.read_pending ~keepers_dir ~keeper_id:keeper_name) in
  let* _anchor=io (fun () -> Current.capture_program_anchor ~keepers_dir ~keeper_id:keeper_name) in
  let* owner=io (fun () -> Capture.observe_owner ~base_path ~keepers_dir ~keeper_id:keeper_name) in
  let* ()=io (fun () -> recover_closure ~store ~owner ~after_settle) in
  (* Complete discovery precedes every local repair or new publication. *)
  let* initial=io (fun () -> discover ~store ~owner) in
  let* ()=io (fun () -> Queue.acknowledge_committed ~keepers_dir ~keeper_id:keeper_name) in
  let* pending=read () in
  let* _recovered=io (fun () -> Parts.recover_partitions ~store ~owner) in
  let* ()=io (fun () -> List.fold_left (fun result original ->
    let* ()=result in
    match Progress.preparation original.record.progress with
    | Some (Preparation_pending _) ->
      Gate_journal.recover_root ~store ~owner ~capture:original.capture |> Result.map (fun _ -> ())
    | None | Some (Preparation_confirmed _) -> Ok ()) (Ok ()) initial.executions) in
  let* ()=io (fun () -> List.fold_left (fun result original ->
    let* ()=result in Gate_journal.recover_retries ~store ~owner ~capture:original.capture)
    (Ok ()) initial.executions) in
  let* inventory=io (fun () -> discover ~store ~owner) in
  let* closed=io (fun () -> close_completed_forest ~store ~owner ~after_settle inventory) in
  let* inventory=if closed then io (fun () -> discover ~store ~owner) else Ok inventory in
  (* A new root needs the live destination, so without the Add-on the
     pending candidates stay queued and the pass reports the Add-on off. *)
  let root ?supersession batch =
    if unattached ~config ~reserved then Ok None
    else let* root=retain_root ~store ~config ~reserved ~owner ?supersession batch in
      Ok (Some ([root],Written_since_read)) in
  (* Finding the frontier and proving a supersession only read, so the
     existing leaves are walked with the inventory read after recovery. *)
  let existing=Some (Parts.runnable inventory.parts,Read_after_last_write inventory) in
  let* parts=match Parts.roots inventory.parts,pending with
    | [],None -> Ok (Some ([],Read_after_last_write inventory))
    | [],Some batch -> root batch
    | _::_,None ->
      (* With no pending input and every runnable leaf terminal there is
         nothing to evaluate: walking would only confirm finished parts
         again. The walk is empty and the pass reports [Idle]. *)
      let* frontier=frontier ~store ~owner inventory in
      (match frontier with
       | Some _ -> Ok (Some ([],Read_after_last_write inventory))
       | None -> Ok existing)
    | _::_,Some batch ->
      let* frontier=frontier ~store ~owner inventory in
      (match frontier with
       | None -> Ok existing
       | Some frontier ->
         let* supersession=io (fun () -> Parts.prove_supersession ~store ~owner
           ~inventory:inventory.parts ~batch ~frontier) in
         match supersession with
         | None -> Ok existing
         | Some supersession -> root ~supersession batch) in
  let addon_unattached () =
    let* pending=read () in
    Ok (Addon_unattached {pending=Option.fold ~none:0 ~some:(fun batch -> List.length (Queue.candidates batch)) pending}) in
  match parts with
  | None -> addon_unattached ()
  | Some (parts,held) ->
  let through=List.fold_left (fun through part -> max through (Parts.original_through part)) 0 parts in
  let finish ~committed ~reason =
    let* pending=read () in
    let has_more=Option.fold ~none:false ~some:(fun batch ->
      List.exists (fun (row : Queue.candidate) -> row.sequence>through) (Queue.candidates batch)) pending in
    if committed then (
      (* A quiet Keeper may receive no further Runtime/input event. Notify
         the existing latest-wins lane only after a complete normal frontier
         qualifies, never merely because the queue is empty or one sibling
         reconfirmed a prior commit. Keep the actual commit outcome even if
         this subsequent maintenance observation fails. *)
      let closing=io (fun () ->
        let* current=discover ~store ~owner in completed_forest ~store ~owner current) in
      (match closing with
       | Ok (Some _) -> Keeper_librarian_queue_signal.changed ~base_path ~keeper_name
       | Ok None -> ()
       | Error detail -> Log.Keeper.warn ~keeper_name "Librarian admission closure postponed: %s" detail);
      Ok (Settled {has_more}))
    else if has_more then Ok Recheck_new_input
    else match pending,parts with
      | None,[] -> Ok Idle
      | (None | Some _),(_::_ | []) -> Ok (Pending reason) in
  (* Every evaluation may write (a dispatch, a gate, a commit, a partition or
     a settle), so each part after the first reads the inventory again. *)
  let rec walk ~committed ~held = function
    | [] -> finish ~committed ~reason:"Original admission awaits further evidence"
    | part::rest ->
      let* inventory=match held with
        | Read_after_last_write inventory -> Ok inventory
        | Written_since_read -> io (fun () -> discover ~store ~owner) in
      (match evaluate ~store ~config ~reserved ~owner ~inventory part with
       | Error detail -> Error detail
       | Ok (Waiting reason) ->
         (* A new tail cannot run while this immutable frontier is unresolved.
            Only a completed walk may request another immediate queue pass;
            actual Runtime/candidate events wake waiting originals. *)
         Ok (if committed then Settled {has_more=false} else Pending reason)
       | Ok (Worker_wait wait) -> Ok (Awaiting_worker wait)
       | Ok Addon_off -> if committed then Ok (Settled {has_more=false}) else addon_unattached ()
       | Ok (Terminal (_,did_commit)) ->
         walk ~committed:(committed || did_commit) ~held:Written_since_read rest
       | Ok (Children (left,right)) -> walk ~committed ~held:Written_since_read (left::right::rest)
       (* The fresh execution's attempt carries this process's incarnation, so
          a cut of it reads as [Cut] and the part does not settle twice. *)
       | Ok Reprepared -> walk ~committed ~held:Written_since_read (part::rest)) in
  walk ~committed:false ~held parts
let run_enabled ~after_settle ~base_path ~keeper_name =
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let* generation=io (fun () -> Queue.read_generation ~keepers_dir ~keeper_id:keeper_name) in
  match generation with None -> Ok Idle | Some _ -> run_queue ~after_settle ~base_path ~keeper_name
let run_with ~after_settle ~base_path ~keeper_name =
  match Env_config.KeeperMemoryOs.librarian_config_state () with
  | Disabled | Invalid -> Disabled
  | Enabled -> match run_enabled ~after_settle ~base_path ~keeper_name with
    | Ok result -> result | Error detail -> Unavailable detail
let run ~base_path ~keeper_name=run_with ~after_settle:(fun _ -> Ok ()) ~base_path ~keeper_name
module For_testing = struct
  let run=run_with
end
