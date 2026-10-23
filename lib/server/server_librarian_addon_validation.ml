module Capture = Keeper_librarian_admission_capture
module Parts = Keeper_librarian_admission_parts
module Gate = Keeper_librarian_admission_gate
module Owner = Lane_addon_tool_request_owner
module Exact = Lane_addon_exact
let ( let* ) = Result.bind
let io work = Eio_unix.run_in_systhread work

type authorization = {
  validate_output : Exact.output_validator;
  before_dispatch : Exact.dispatch_guard;
  with_execution : Exact.execution_scope;
}

let authorize ~base_path ~store ~declaration_id ~(package : Lane_addon_types.package)
    (request : Exact.request) =
  match Capture.scope_of_request_id request.request_id with
  | Error _ ->
    if package.id=Capture.package_id then Error "Librarian exact request lacks its original host identity"
    else Ok None
  | Ok scope ->
    io (fun () ->
      let* record=Owner.load ~store ~scope ~request_id:request.request_id
        |> Result.map_error Owner.error_to_string in
      let* record=match record with Some record -> Ok record
        | None -> Error "Namespaced Librarian exact request has no original host capture" in
      let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
      let* owner=Capture.observe_record_owner ~base_path ~keepers_dir record in
      let restore_gate ~parent_execution ~gate_request_id =
        Gate.restore_size_evidence ~store ~owner ~parent_execution ~gate_request_id in
      let* inventory=Parts.discover ~store ~owner ~restore_gate in
      let* capture=Capture.restore ~owner
        ~load_parent:(Parts.load_parent inventory) record in
      let destination=Capture.destination capture in
      let* ()=if destination.installation_id=Owner.installation_id (Owner.Configuration declaration_id)
          && destination.package_id=Capture.package_id && package.id=Capture.package_id
          && destination.tool=Capture.tool
        then Ok () else Error "Librarian original does not own this configured installation/package/tool" in
      let* original=Capture.request capture in
      let* ()=if Exact.digest original=Exact.digest request then Ok ()
        else Error "Librarian exact request differs from its original captured input/schema" in
      Ok (Some {
        validate_output=(fun proposal -> Capture.validate_proposal capture proposal |> Result.map (fun _ -> ()));
        before_dispatch=(fun () ->
          let* ()=io (fun () ->
            let* fresh=Owner.load ~store ~scope ~request_id:request.request_id
              |> Result.map_error Owner.error_to_string in
            let* fresh=match fresh with Some fresh -> Ok fresh
              | None -> Error "Original Librarian request disappeared before provider dispatch" in
            let* ()=if fresh.request_digest=record.request_digest && fresh.request=record.request
                && fresh.installation_id=record.installation_id && fresh.package_id=record.package_id
                && fresh.tool=record.tool then Ok ()
              else Error "Original Librarian immutable owner changed before provider dispatch" in
            let* actual=Capture.observe_record_owner ~base_path ~keepers_dir fresh in
            Capture.owner_matches_json actual (Capture.owner_to_json owner)) in
          Lane_addon_runtime.authorize_captured_exact_dispatch
            ~store ~declaration_id ~package_id:destination.package_id
            ~configuration_revision:destination.configuration_revision);
        with_execution=(fun run ->
          match Keeper_memory_lane.with_external_effect ~base_path ~keeper_name:(Capture.keeper_id owner) run with
          | Ok result -> result
          | Error error -> Error (Keeper_memory_lane.external_effect_error_to_string error));
      }))
