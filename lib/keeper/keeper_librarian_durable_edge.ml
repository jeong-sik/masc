module Request = Keeper_librarian_durable_request
module Retained = Lane_addon_tool_request_owner
module Runtime = Lane_addon_runtime
module Submit = Lane_addon_submit_once
let ( let* ) = Result.bind
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f
let require condition detail = if condition then Ok () else Error detail
let runtime_error = function
  | Runtime.Unavailable detail | Outcome_unknown detail -> detail
  | Host_refusal refusal -> match refusal with
    | Lane_addon_call_context.Rejected detail | Unavailable detail
    | Activity_disabled detail | Activity_unobserved detail -> detail
let reserved = Keeper_librarian_addon.reserved
let resolve ~config ~reserved =
  match Keeper_librarian_addon.resolve ~config ~reserved Keeper_librarian_addon.Durable with
  | Ok export -> Ok (Some export)
  | Error Keeper_librarian_addon.Unattached -> Ok None
  | Error ((Unready _ | Export_conflict _ | Wrong_package _ | Manual_installation) as reason) ->
    Error (Keeper_librarian_addon.unavailable_to_string reason)
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
let fresh_authority ~config ~reserved ~owner ~expected () =
  let* ()=io (fun () ->
    let base_path=config.Workspace.base_path in
    let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let* current=Request.observe_owner ~base_path ~keepers_dir ~keeper_id:(Request.keeper_id owner) in
    Request.owner_matches_json current (Request.owner_to_json owner)) in
  with_destination ~config ~reserved (fun actual ->
    require (same_destination actual expected)
      "Original completed-history Librarian semantic configuration changed")
let call ~config ~reserved ~(expected : Request.destination) ~(original : Retained.retained) ~arguments =
  match resolve ~config ~reserved with
  | Error detail -> Error (Submit.Not_sent (Submit.Rejected detail))
  | Ok None -> Error (Submit.Not_sent (Submit.Unavailable "Completed-history Librarian Addon is not attached"))
  | Ok (Some export) ->
    Runtime.call_captured_tool_request ~config ~reserved ~export
      ~access:Lane_addon_sources.Operator_configuration
      ~installation_id:expected.installation_id ~package_id:expected.package_id
      ~tool:expected.tool ~configuration_revision:expected.configuration_revision ~original ~arguments
    |> Result.map_error Submit.call_error_of_runtime
