module Capture = Workspace_memory_execution_capture
module Exact = Lane_addon_exact
module Owner = Lane_addon_tool_request_owner
let ( let* ) = Result.bind

let package_id = "workspace-curator"
let tool = "curate"

let request capture =
  let output = match Capture.work capture with
    | Capture.Classification _ -> "classification"
    | Capture.Briefing _ -> "briefing" in
  Exact.request_of_json (`Assoc [
    "kind", `String "exact_output";
    "request_id", `String (Capture.Request_id.to_string (Capture.request_id capture));
    "output", `String output;
    "messages", `List [`Assoc ["role", `String "user";
      "text", `String (Capture.rendered_prompt capture)]];
    "schema", Capture.output_schema capture])

let authorize ~base_path ~store ~declaration_id ~(package : Lane_addon_types.package)
    (exact : Exact.request) =
  let* retained = Owner.load ~store ~scope:Capture.scope ~request_id:exact.request_id
    |> Result.map_error Owner.error_to_string in
  match retained with
  | None ->
    if String.equal package.id package_id then Error "Curator exact request has no original host capture"
    else Ok (fun _ -> Ok ())
  | Some retained ->
    let* workspace = Eio_unix.run_in_systhread (fun () -> Capture.observe_workspace ~base_path) in
    let* capture = Eio_unix.run_in_systhread (fun () -> Capture.restore ~workspace
      ~load:(fun ~request_id -> Owner.load ~store ~scope:Capture.scope ~request_id
        |> Result.map_error Owner.error_to_string) retained) in
    let destination = Capture.destination capture in
    let* () =
      if String.equal destination.installation_id (Owner.installation_id (Owner.Configuration declaration_id))
         && String.equal package.id package_id
         && String.equal destination.package_id package.id
         && String.equal destination.tool tool
      then Ok () else Error "Curator exact request does not own this installation/package/tool" in
    let* original = request capture in
    let* () = if String.equal (Exact.digest original) (Exact.digest exact) then Ok ()
      else Error "Curator exact request differs from its original captured prompt/schema/kind" in
    Ok (fun answer -> Capture.validate_output capture answer |> Result.map (fun _ -> ()))
