module Request = Keeper_librarian_durable_request
module Owner = Keeper_librarian_durable_owner
module Retained = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Runtime = Lane_addon_runtime
module Consumer = Keeper_librarian_durable_consumer
module Source = Keeper_librarian_durable_capture
module Current = Keeper_memory_os_current
module Submit = Lane_addon_submit_once
let ( let* ) = Result.bind
let io = Domain_pool_ref.submit_io_or_inline
let require condition detail = if condition then Ok () else Error detail
let runtime_error = function
  | Runtime.Unavailable detail | Outcome_unknown detail -> detail
  | Host_refusal refusal -> match refusal with
    | Lane_addon_call_context.Rejected detail | Unavailable detail
    | Activity_disabled detail | Activity_unobserved detail -> detail
let reserved () =
  List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) Config.raw_all_tool_schemas
  @ (Keeper_tool_descriptor.all_descriptors () |> List.concat_map Keeper_tool_descriptor.registered_names)
  |> List.sort_uniq String.compare
let resolve ~config ~reserved =
  let snapshot=Runtime.tool_export_snapshot ~config ~reserved ~access:Lane_addon_sources.Operator_configuration in
  match List.find_opt (fun (conflict : Lane_addon_tool_export.conflict) -> conflict.name=Request.tool) snapshot.conflicts with
  | Some conflict -> Error (Lane_addon_tool_export.conflict_to_string conflict)
  | None ->
    match List.find_opt (fun (export : Runtime.tool_export) -> export.tool.name=Request.tool) snapshot.exports with
    | None -> Ok None
    | Some export -> Ok (Some export)
let destination (value : Runtime.tool_request_destination) : Request.destination = {
  installation_id=value.installation_id;package_id=value.package_id;tool=value.tool;
  source_revision=value.source_revision;configuration_revision=value.configuration_revision}
let same_destination (left : Request.destination) (right : Request.destination) =
  left.installation_id=right.installation_id && left.package_id=right.package_id
  && left.tool=right.tool && left.configuration_revision=right.configuration_revision
let with_destination ~config ~reserved publish =
  let* export=resolve ~config ~reserved in
  let* export=Option.to_result ~none:"Completed-history Librarian Addon is not attached" export in
  Runtime.with_tool_request_destination ~config ~reserved ~export
    ~access:Lane_addon_sources.Operator_configuration ~publish:(fun actual ->
      let actual=destination actual in
      if actual.package_id<>Request.package_id || actual.tool<>Request.tool
      then Error (Runtime.Host_refusal (Lane_addon_call_context.Rejected
        "Completed-history Librarian requires its configured package/tool"))
      else match publish actual with Ok value -> Ok value | Error detail -> Error (Runtime.Unavailable detail))
  |> Result.map_error runtime_error
let fresh_authority ~config ~reserved request () =
  let* ()=io (fun () ->
    let base_path=config.Workspace.base_path in
    let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let* owner=Request.observe_owner ~base_path ~keepers_dir
      ~keeper_id:(Request.keeper_id (Request.physical_owner request)) in
    Request.owner_matches_json owner (Request.owner_to_json (Request.physical_owner request))) in
  with_destination ~config ~reserved (fun actual ->
    require (same_destination actual (Request.destination request))
      "Original completed-history Librarian semantic configuration changed")
let call ~config ~reserved ~expected ~(original : Retained.retained) ~arguments =
  match resolve ~config ~reserved with
  | Error detail -> Error (Submit.Not_sent (Submit.Rejected detail))
  | Ok None -> Error (Submit.Not_sent (Submit.Unavailable "Completed-history Librarian Addon is not attached"))
  | Ok (Some export) ->
    Runtime.call_captured_tool_request ~config ~reserved ~export
      ~access:Lane_addon_sources.Operator_configuration
      ~installation_id:expected.Request.installation_id ~package_id:expected.package_id
      ~tool:expected.tool ~configuration_revision:expected.configuration_revision ~original ~arguments
    |> Result.map_error Submit.call_error_of_runtime
let active (record : Retained.retained) = match Progress.phase record.progress with
  | Progress.Finished _ -> false
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> true
let resume ~store ~config ~reserved ~wake (original,request) =
  Owner.resume ~store ~config ~reserved ~original ~request ~wake ~call:(call ~config ~reserved)
    ~publish:(fun ~original ~request ~proposal ->
      Keeper_librarian_durable_commit.publish ~store ~config ~original ~request ~proposal
        ~fresh_authority:(fresh_authority ~config ~reserved request)
      |> Result.map_error (fun detail -> Owner.Rejected detail))
  |> Result.map_error Owner.error_to_string
let capture ~store ~config ~reserved ~keeper_name source =
  let base_path=config.Workspace.base_path in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let* owner=io (fun () ->
    let* anchor=Current.capture_program_anchor ~keepers_dir ~keeper_id:keeper_name in
    let snapshot=Current.program_anchor_snapshot anchor in
    let revision=Option.map (fun (snapshot : Current.t) -> snapshot.revision) snapshot in
    let current=Option.map (fun (snapshot : Current.t) ->
      ({Keeper_librarian.facts=snapshot.facts} : Keeper_librarian.current_selection)) snapshot in
    let* ()=require (revision=Source.expected_revision source && current=(Source.input source).current)
      "Memory changed before the original completed-history capture" in
    Request.observe_owner ~base_path ~keepers_dir ~keeper_id:keeper_name) in
  let* preparation=Keeper_librarian_runtime.prepare_durable ~now:(Time_compat.now ()) (Source.input source) in
  let request_id=Request.fresh_request_id owner in
  (* Factory/retention performs local I/O under the actual configuration/action
     serializers. capture_tool_request_owner's factory is pure, so use the
     destination publication port rather than placing I/O in that factory. *)
  with_destination ~config ~reserved (fun destination ->
    let* request=io (fun () -> Request.create ~request_id ~owner ~destination ~source ~preparation) in
    let* original=Owner.retain ~store request |> Result.map_error Owner.error_to_string in
    Ok (original,request))
let completed_outcome request =
  let source=Request.source request in
  let atom=Option.map (fun (range : Current.durable_range_id) ->
    {Keeper_librarian_progress.position={trace_id=range.trace_id;end_atom=range.end_atom;
      last_atom_digest=range.last_atom_digest};boundary_lines_seen=range.boundary_lines_seen}) (Source.range_id source) in
  match Source.official_range_id source,atom with
  | Some official,_ ->
    let boundary_line=List.fold_left (fun latest (line,_) -> max latest line)
      official.after_boundary_line official.turns in
    Consumer.Official_advanced {atom;official={Keeper_librarian_official_progress.boundary_line}}
  | None,Some progress -> Consumer.Progress_advanced progress
  | None,None -> Consumer.Nothing_to_read
let consume_one ~config ~keeper_name ~wake =
  let base_path=config.Workspace.base_path in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let reserved=reserved () in
  let error detail=Error (Consumer.Original_publication_blocked detail) in
  let resume_original ((_,request) as original) =
    match resume ~store ~config ~reserved ~wake original with
    | Error detail -> error detail
    | Ok (Owner.Finished _) -> Ok (completed_outcome request)
    | Ok (Pending _ | Publication_waiting _) -> Ok Consumer.Pending
    | Ok (Refused _) -> Ok (Consumer.Memory_not_committed []) in
  (* Discovery does not initialize an epoch or create a replacement request.
     Any malformed old original fails the full inventory before fresh selection. *)
  match Owner.discover ~store ~base_path ~keepers_dir ~keeper_id:keeper_name with
  | Error failure -> error (Owner.error_to_string failure)
  | Ok originals ->
    let validated=List.fold_left (fun result (record,request) ->
      let* ()=result in
      io (fun () -> Keeper_librarian_durable_commit.validate ~store ~request ~record)) (Ok ()) originals in
    match validated with
    | Error detail -> error detail
    | Ok () ->
    let unfinished=List.filter (fun (record,_) -> active record) originals in
    match unfinished with
    | _::_::_ -> error "Completed-history Librarian has multiple unfinished original owners"
    | [original] -> resume_original original
    | [] ->
      match resolve ~config ~reserved with
      | Error detail -> error detail
      | Ok None -> Ok (Consumer.Memory_not_committed [])
      | Ok (Some _) ->
        let failure=ref None in
        let commit source =
          match capture ~store ~config ~reserved ~keeper_name source with
          | Error detail -> failure:=Some detail;Consumer.Memory_pending
          | Ok original ->
            match resume ~store ~config ~reserved ~wake original with
            | Error detail -> failure:=Some detail;Consumer.Memory_pending
            | Ok (Owner.Finished _) -> Consumer.Memory_committed
            | Ok (Pending _ | Publication_waiting _) -> Consumer.Memory_pending
            | Ok (Refused _) -> Consumer.Memory_refused [] in
        let result=Consumer.consume_one ~config ~keeper_name ~commit in
        match !failure with Some detail -> error detail | None -> result
