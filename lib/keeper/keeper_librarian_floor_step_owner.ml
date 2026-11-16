module Step = Keeper_librarian_floor_step_request
module Durable = Keeper_librarian_durable_request
module Edge = Keeper_librarian_durable_edge
module Memory_runtime = Keeper_librarian_runtime
module Owner = Lane_addon_tool_request_owner
module Exact = Lane_addon_exact
module Submit = Lane_addon_submit_once
module Progress = Lane_addon_request_progress
module Replacement = Keeper_librarian_declaration_replacement
let ( let* ) = Result.bind
let ( let+ ) result f = Result.map f result
type error = Submit.error = Unavailable of string | Rejected of string | Uncertain of string
let error_to_string = Submit.error_to_string
type wait = Submit.wait = Worker_pending | Worker_unknown | Worker_unreachable
  | Missing_after_dispatch | Journal_recheck
type call = expected:Durable.destination -> original:Owner.Record.t -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result,Submit.call_error) result
type answer = {raw:Yojson.Safe.t;proposal:Memory_runtime.durable_step_proposal}
type outcome = Pending of wait * Owner.retained
  | Answered of answer * Owner.retained
  | Refused of Exact.final * Owner.retained
  | Before_dispatch_replaced of Owner.retained
let io work = Systhread_host.run work
let rejected value = Result.map_error (fun detail -> Rejected detail) value
let owned value = Result.map_error (fun error -> Unavailable (Owner.error_to_string error)) value
let check_record step record = rejected (Step.confirm_record step record)
let retain ~store step =
  let* ()=io (fun () -> Step.confirm_owner step) |> rejected in
  let destination=Step.destination step in
  let scope=Step.scope (Step.physical_owner step) and request_id=Step.request_id step in
  let* ()=io (fun () -> Owner.retain ~store ~scope ~request_id
    ~installation_id:destination.installation_id ~package_id:destination.package_id ~tool:destination.tool
    ~summary:`Null ~request:(Step.to_json step)) |> owned in
  let* record=io (fun () -> Owner.load ~store ~scope ~request_id) |> owned in
  let* record=match record with Some record -> Ok record
    | None -> Error (Uncertain "Retained original floor step is not observable") in
  let* ()=check_record step record in Ok record
let discover ~store ~owner =
  let* records=io (fun () -> Owner.load_scope ~store ~scope:(Step.scope owner)) |> owned in
  let rec headers found = function
    | [] -> Ok (List.rev found)
    | record::rest ->
      let* header=io (fun () -> Step.header ~owner record) |> rejected in
      headers ((record,header)::found) rest in
  headers [] records
let schema_of step =
  let* exact=rejected (Step.request step) in
  match exact.Exact.schema with
  | Some schema -> Ok schema
  | None -> Error (Rejected "Original floor step request has no output schema")
type terminal = Answer of answer * Owner.retained
  | Refusal of Exact.final * Owner.retained
let refused final record = match final with
  | Exact.Outcome_unknown -> Pending (Worker_unknown,record)
  | Call_final _ | Not_allowed _ | Request_id_reused -> Refused (final,record)
type admission_check = Admission_continues | Admission_unavailable
  | Admission_replaced of Owner.retained
let resume ~store ~config ~reserved ~(original:Owner.retained) ~step ~(call:call) =
  let owner=Step.physical_owner step in
  let confirm_live_owner () =
    let base_path=config.Workspace.base_path in
    let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let* actual=io (fun () -> Durable.observe_owner ~base_path ~keepers_dir ~keeper_id:(Durable.keeper_id owner))
      |> rejected in
    rejected (Durable.owner_matches_json actual (Durable.owner_to_json owner)) in
  let* ()=check_record step original in
  let* ()=confirm_live_owner () in
  let* exact=rejected (Step.request step) in
  let* schema=schema_of step in
  let destination=Step.destination step in
  let* admission=match Progress.phase original.progress with
    | Progress.Captured | Admission_wait _ ->
      (match Edge.observe_destination ~config ~reserved destination with
       | Error (Submit.Unavailable _ | Rejected _ | Uncertain _) -> Ok Admission_unavailable
       | Ok current ->
         match Lane_addon_captured_destination.relation ~captured:destination ~current with
         | Same -> Ok Admission_continues
         | Other_owner -> Error (Rejected "Fresh floor destination belongs to another original owner")
         | Replaced ->
           let* record=io (fun () -> Replacement.refuse ~store ~original:(Owner.listed original)
             ~exact_digest:(Exact.digest exact) ~captured:destination ~current) in
           let+ original=match Owner.rebind original record with
             | Some original -> Ok original
             | None -> Error (Rejected "Replaced floor step changed its original binding") in
           Admission_replaced original)
    | Rejected {stage=Before_dispatch;_} ->
      let* replaced=Replacement.retained ~original:(Owner.listed original) ~captured:destination |> rejected in
      let* ()=io (fun () -> Replacement.confirm_no_execution ~store ~original:(Owner.listed original)
        ~exact_digest:(Exact.digest exact)) |> rejected in
      if replaced then Ok (Admission_replaced original) else Ok Admission_continues
    | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
    | Rejected {stage=Execution;_} | Subdividing _ | Subdivided _ -> Ok Admission_continues in
  match admission with
  | Admission_unavailable -> Ok (Pending (Worker_unreachable,original))
  | Admission_replaced original ->
    let* ()=confirm_live_owner () in
    Ok (Before_dispatch_replaced original)
  | Admission_continues ->
  let prepare () =
    let* ()=confirm_live_owner () in
    Edge.confirm_destination ~config ~reserved destination in
  let admit () =
    let* ()=Memory_runtime.require_counterpart_template (Step.step step).preparation |> rejected in
    prepare () in
  let call ~arguments =
    match prepare () with
    | Error error -> Error (Submit.Not_sent error)
    | Ok () -> call ~expected:destination ~original:(Owner.listed original) ~arguments in
  let terminal record final =
    let* ()=confirm_live_owner () in
    let* ()=io (fun () -> Step.confirm_final ~store step final) |> rejected in
    match final with
    | Exact.Call_final (Exact.Answered {output;_}) ->
      let raw=Exact.checked_json output in
      let* proposal=rejected (Step.validate_proposal step raw) in
      Ok (Answer ({raw;proposal},record))
    | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
    | Outcome_unknown | Not_allowed _ | Request_id_reused -> Ok (Refusal (final,record)) in
  let decode_final json=io (fun () -> Step.decode_final ~store step json) in
  (* A step is not ended here. [prepare] refuses a changed destination. *)
  let* result=Submit.resume_retained ~store ~label:"Floor step" ~original ~request:exact ~schema ~decode_final
    ~unadmitted:(fun () -> Ok Submit.Admit) ~prepare:admit ~call ~terminal in
  match result with
  | Submit.Awaiting (wait,record) -> Ok (Pending (wait,record))
  | Final (Answer (answer,record)) -> Ok (Answered (answer,record))
  | Final (Refusal (final,record)) -> Ok (refused final record)
  (* A retained answer ([Judged]) or refusal ([Rejected]) runs [terminal] again
     above, so what is left here are the phases no step writes: its Memory
     commit belongs to the chain and no step writes a split into successors.
     A declaration replacement before dispatch was handled above. *)
  | Commit_pending _ | Settled _ -> Error (Rejected "Original floor step is in a phase no step writes")
