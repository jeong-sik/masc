module Step = Keeper_librarian_floor_step_request
module Durable = Keeper_librarian_durable_request
module Edge = Keeper_librarian_durable_edge
module Memory_runtime = Keeper_librarian_runtime
module Owner = Lane_addon_tool_request_owner
module Exact = Lane_addon_exact
module Submit = Lane_addon_submit_once
let ( let* ) = Result.bind
type error = Submit.error = Unavailable of string | Rejected of string | Uncertain of string
let error_to_string = Submit.error_to_string
type wait = Submit.wait = Capacity | Worker_pending | Worker_unknown | Worker_unreachable
  | Missing_after_dispatch | Journal_recheck
type call = expected:Durable.destination -> original:Owner.retained -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result,Submit.call_error) result
type outcome = Pending of wait * Owner.retained
  | Answered of Memory_runtime.durable_step_proposal * Owner.retained
  | Refused of Exact.final * Owner.retained
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
type terminal = Answer of Memory_runtime.durable_step_proposal * Owner.retained
  | Refusal of Exact.final * Owner.retained
let refused final record = match final with
  | Exact.Outcome_unknown -> Pending (Worker_unknown,record)
  | Call_final _ | Not_allowed _ | Request_id_reused -> Refused (final,record)
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
  let prepare () =
    let* ()=confirm_live_owner () in
    Edge.confirm_destination ~config ~reserved destination in
  let call ~arguments =
    match prepare () with
    | Error error -> Error (Submit.Not_sent error)
    | Ok () -> call ~expected:destination ~original ~arguments in
  let terminal record final =
    let* ()=confirm_live_owner () in
    let* ()=io (fun () -> Step.confirm_final ~store step final) |> rejected in
    match final with
    | Exact.Call_final (Exact.Answered {output;_}) ->
      let* proposal=rejected (Step.validate_proposal step (Exact.checked_json output)) in
      Ok (Answer (proposal,record))
    | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
    | Outcome_unknown | Not_allowed _ | Request_id_reused -> Ok (Refusal (final,record)) in
  let* result=Submit.resume ~store ~label:"Floor step" ~original ~request:exact ~schema ~prepare ~call ~terminal in
  match result with
  | Submit.Awaiting (wait,record) -> Ok (Pending (wait,record))
  | Final (Answer (proposal,record)) -> Ok (Answered (proposal,record))
  | Final (Refusal (final,record)) -> Ok (refused final record)
  (* A retained answer ([Judged]) or refusal ([Rejected]) runs [terminal] again
     above, so what is left here are the phases no step writes: its Memory
     commit belongs to the chain, and a refusal before dispatch or a split
     into successors is not a step's. *)
  | Commit_pending _ | Settled _ -> Error (Rejected "Original floor step is in a phase no step writes")
