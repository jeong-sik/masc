module Capture = Keeper_librarian_admission_capture
module Parts = Keeper_librarian_admission_parts
module Gate = Keeper_librarian_admission_gate
module Owner = Lane_addon_tool_request_owner
module Exact = Lane_addon_exact
module History = Keeper_librarian_durable_request
module Step = Keeper_librarian_floor_step_request
module Namespace = Keeper_librarian_request_namespace
open Result.Syntax
let io work = Systhread_host.run work
let undecided detail = Exact.Undecided {detail}
let load_original ~store ~scope ~request_id =
  let* record = Owner.load ~store ~scope ~request_id
    |> Result.map_error (fun error -> undecided (Owner.error_to_string error)) in
  match record with
  | Some record -> Ok record
  | None -> Error (Exact.Unowned {reason="Namespaced Librarian request has no original host capture"})

type authorization = {
  validate_output : Exact.output_validator;
  before_dispatch : Exact.dispatch_guard;
  with_execution : Exact.execution_scope;
}

let authorize_history ~base_path ~store ~declaration_id ~(package:Lane_addon_types.package)
    (request:Exact.request) scope =
  io (fun () ->
    let* record=load_original ~store ~scope ~request_id:request.request_id in
    let restore () =
    let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let* owner=History.observe_record_owner ~base_path ~keepers_dir record in
    let* capture=History.restore ~owner record in
    let* ()=History.confirm_predecessor ~store ~require_confirmed:true capture in
    let destination=History.destination capture in
    let* ()=if destination.installation_id=Owner.installation_id (Owner.Configuration declaration_id)
        && destination.package_id=History.package_id && package.id=History.package_id
        && destination.tool=History.tool
      then Ok () else Error "History original does not own this configured installation/package/tool" in
    let* original=History.request capture in
    let* ()=if Exact.digest original=Exact.digest request then Ok ()
      else Error "History Exact request differs from its complete original input/schema/purpose" in
    Ok (Some {
      validate_output=(fun proposal -> History.validate_proposal capture proposal |> Result.map (fun _ -> ()));
      before_dispatch=(fun () ->
        let* ()=io (fun () ->
          let* fresh=Owner.load ~store ~scope ~request_id:request.request_id
            |> Result.map_error Owner.error_to_string in
          let* fresh=Option.to_result ~none:"Original history request disappeared before provider dispatch" fresh in
          let* ()=if fresh.request_digest=record.request_digest && fresh.request=record.request
              && fresh.installation_id=record.installation_id && fresh.package_id=record.package_id
              && fresh.tool=record.tool then Ok ()
            else Error "Original history immutable host binding changed before provider dispatch" in
          let* actual=History.observe_record_owner ~base_path ~keepers_dir fresh in
          let* ()=History.owner_matches_json actual (History.owner_to_json owner) in
          let* capture=History.restore ~owner:actual fresh in
          History.confirm_predecessor ~store ~require_confirmed:true capture) in
        Lane_addon_runtime.authorize_captured_exact_dispatch ~store ~declaration_id
          ~package_id:destination.package_id ~configuration_revision:destination.configuration_revision);
      with_execution=(fun run ->
        match Keeper_memory_lane.with_external_effect ~base_path ~keeper_name:(History.keeper_id owner) run with
        | Ok result -> result
        | Error error -> Error (Keeper_memory_lane.external_effect_error_to_string error));
    }) in
    restore () |> Result.map_error undecided)

(* A floor step restores from its own record, so the host validates a model's
   answer to it with the step's own input. It has no predecessor publication to
   confirm: the chain orders its steps by creating each one after the answer
   to the step before it. *)
let authorize_floor_step ~base_path ~store ~declaration_id ~(package:Lane_addon_types.package)
    (request:Exact.request) scope =
  io (fun () ->
    let* record=load_original ~store ~scope ~request_id:request.request_id in
    let restore () =
    let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let* owner=Step.observe_record_owner ~base_path ~keepers_dir record in
    let* step=Step.restore ~owner record in
    let destination=Step.destination step in
    let* ()=if destination.installation_id=Owner.installation_id (Owner.Configuration declaration_id)
        && destination.package_id=History.package_id && package.id=History.package_id
        && destination.tool=History.tool
      then Ok () else Error "Floor step original does not own this configured installation/package/tool" in
    let* original=Step.request step in
    let* ()=if Exact.digest original=Exact.digest request then Ok ()
      else Error "Floor step Exact request differs from its complete original input/schema/purpose" in
    Ok (Some {
      validate_output=(fun proposal -> Step.validate_proposal step proposal |> Result.map (fun _ -> ()));
      before_dispatch=(fun () ->
        let* ()=io (fun () ->
          let* fresh=Owner.load ~store ~scope ~request_id:request.request_id
            |> Result.map_error Owner.error_to_string in
          let* fresh=Option.to_result ~none:"Original floor step disappeared before provider dispatch" fresh in
          let* ()=if fresh.request_digest=record.request_digest && fresh.request=record.request
              && fresh.installation_id=record.installation_id && fresh.package_id=record.package_id
              && fresh.tool=record.tool then Ok ()
            else Error "Original floor step immutable host binding changed before provider dispatch" in
          let* actual=Step.observe_record_owner ~base_path ~keepers_dir fresh in
          History.owner_matches_json actual (History.owner_to_json owner)) in
        Lane_addon_runtime.authorize_captured_exact_dispatch ~store ~declaration_id
          ~package_id:destination.package_id ~configuration_revision:destination.configuration_revision);
      with_execution=(fun run ->
        match Keeper_memory_lane.with_external_effect ~base_path ~keeper_name:(History.keeper_id owner) run with
        | Ok result -> result
        | Error error -> Error (Keeper_memory_lane.external_effect_error_to_string error));
    }) in
    restore () |> Result.map_error undecided)

let authorize ~base_path ~store ~declaration_id ~(package : Lane_addon_types.package)
    (request : Exact.request) =
  match Namespace.of_request_id request.request_id with
  | Namespace.Other ->
    if package.id=Capture.package_id then Error (Exact.Unowned {reason="Librarian exact request lacks its original host identity"})
    else Ok None
  | History scope -> authorize_history ~base_path ~store ~declaration_id ~package request scope
  | Floor_step scope -> authorize_floor_step ~base_path ~store ~declaration_id ~package request scope
  | Admission scope ->
    io (fun () ->
      let* record=load_original ~store ~scope ~request_id:request.request_id in
      let restore () =
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
      }) in
      restore () |> Result.map_error undecided)
