module Capture = Workspace_memory_execution_capture
module Exact = Lane_addon_exact
module Owner = Lane_addon_tool_request_owner
let ( let* ) = Result.bind

let package_id = Capture.package_id
let tool = Capture.tool

let classification_output = "classification"
let briefing_output = "briefing"

let exact_request ~request_id ~output ~rendered_prompt ~schema =
  Exact.request_of_json (`Assoc [
    "kind", `String "exact_output";
    "request_id", `String (Capture.Request_id.to_string request_id);
    "output", `String output;
    "messages", `List [`Assoc ["role", `String "user"; "text", `String rendered_prompt]];
    "schema", schema])

let request capture =
  let output = match Capture.work capture with
    | Capture.Classification _ -> classification_output
    | Capture.Briefing _ -> briefing_output in
  exact_request ~request_id:(Capture.request_id capture) ~output
    ~rendered_prompt:(Capture.rendered_prompt capture) ~schema:(Capture.output_schema capture)

let submit request = `Assoc ["kind", `String "submit"; "request", Exact.request_to_json request]

let classification_submit_bytes ~request_id (batch : Workspace_memory_request.batch) =
  let* request = exact_request ~request_id ~output:classification_output
      ~rendered_prompt:batch.rendered_prompt ~schema:Workspace_memory_decision.output_schema in
  Ok (Lane_addon_host_delivery.arguments_bytes (submit request))

let check_frame ~max_reply_bytes capture =
  let* request = request capture in
  let bytes = Lane_addon_host_delivery.arguments_bytes (submit request) in
  if bytes <= max_reply_bytes then Ok ()
  else Error (Printf.sprintf
    "Curator request arguments measure %d bytes; the receiving Add-on declares a %d-byte frame"
    bytes max_reply_bytes)

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
