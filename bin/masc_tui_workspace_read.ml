type proof = Request_precondition | Health_identity

type workspace_read_binding = {
  wr_host: string;
  wr_port: int;
  wr_expected: Masc.Tui_decode.server_identity;
  wr_proof: proof;
}

let workspace_read_key : workspace_read_binding Eio.Fiber.key = Eio.Fiber.create_key ()

(* The asking fiber owns the binding, including parallel child reads. The
   concrete URL is built before the transport crosses to the IO domain.
   No global mutable workspace setting can leak into a sibling collector. *)
let with_binding ~host ~port ~expected ~proof load =
  Eio.Fiber.with_binding workspace_read_key
    {wr_host=host;wr_port=port;wr_expected=expected;wr_proof=proof} load

let without_binding load =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> load ()
  | Eio_fiber -> Eio.Fiber.without_binding workspace_read_key load

let current_workspace_read () =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> None
  | Eio_fiber -> Eio.Fiber.get workspace_read_key

let workspace_read_path ~host ~port ~path =
  match current_workspace_read () with
  | None -> Ok path
  | Some binding when binding.wr_host <> host || binding.wr_port <> port ->
    Error "Workspace-bound read changed its server endpoint"
  | Some {wr_proof=Health_identity; _} -> Ok path
  | Some {wr_expected;wr_proof=Request_precondition;_} ->
    let uri = Uri.of_string path in
    let fields = Uri.query uri in
    if List.exists (fun (key, _) ->
        key = "expected_base_path" || key = "expected_masc_root") fields then
      Error "Workspace-bound read already supplies a workspace precondition"
    else
      Ok (Uri.to_string (Uri.with_query uri
        (fields @ ["expected_base_path",
                   [Masc.Tui_decode.Canonical_path.to_string wr_expected.sid_base_path];
                   "expected_masc_root",
                   [Masc.Tui_decode.Canonical_path.to_string wr_expected.sid_masc_root]])))

let validate_workspace_read_json json =
  match current_workspace_read () with
  | None | Some {wr_proof=Request_precondition;_} -> Ok json
  | Some {wr_expected;wr_proof=Health_identity;_} ->
    let ( let* ) = Result.bind in
    (* The decode resolves both paths; it runs where every other health
       decode runs, on the CPU pool rather than in this fiber. *)
    let* observed =
      Masc_tui_response_decode.run ~name:"server.identity.decode_wait" (fun () ->
        Masc.Tui_decode.decode_server_identity json) in
    if Masc_tui_types.server_workspace_matches ~expected:(Some wr_expected) (Ok observed)
    then Ok json
    else Error "Health reading belongs to another or unavailable workspace"

let validate_workspace_read_response (response : Masc_http_client.response) =
  match current_workspace_read () with
  | None | Some {wr_proof=Health_identity;_} -> Ok response
  | Some {wr_proof=Request_precondition;_} ->
    if response.status = 304 || (response.status >= 200 && response.status < 300) then
      let name, expected = Masc.Workspace.read_precondition_admission_header in
      let receipts = List.filter_map (fun (key, value) ->
        if String.equal (String.lowercase_ascii key) name then Some value else None) response.headers in
      (match receipts with
       | [value] when String.equal value expected -> Ok response
       | _ -> Error "Server did not attest the requested workspace read")
    else Ok response

(** GET a JSON response from a dashboard endpoint. The answer kept from the
    last read of the same address goes out as [If-None-Match], and a 304
    answers with the value decoded from it. *)
let read_json ~kept_reads ~address_of ~send ~decode ~host ~port ~path =
  let ( let* ) = Result.bind in
  let* path = workspace_read_path ~host ~port ~path in
  let* json =
    Masc_tui_kept_reads.read kept_reads ~address:(address_of ~path)
      ~send:(fun headers ->
        send ~path ~headers
        |> (fun result -> Result.bind result validate_workspace_read_response)
        |> Result.map (fun { Masc_http_client.status; headers; body } ->
             { Masc_tui_kept_reads.status; headers; body }))
      ~decode:(fun { Masc_tui_kept_reads.status; body; _ } ->
        decode ~allow_empty:false ~status_code:status ~body)
  in
  validate_workspace_read_json json

type response_failure = Transport_failed of string | Workspace_refused of string

let read_response ~send ~host ~port ~path =
  match current_workspace_read () with
  | Some {wr_proof=Health_identity;_} ->
    Error (Workspace_refused "A raw response cannot establish the decoded workspace health identity")
  | None | Some {wr_proof=Request_precondition;_} ->
    let ( let* ) = Result.bind in
    let* path = workspace_read_path ~host ~port ~path
      |> Result.map_error (fun detail -> Workspace_refused detail) in
    let* response = send ~path |> Result.map_error (fun detail -> Transport_failed detail) in
    validate_workspace_read_response response
    |> Result.map_error (fun detail -> Workspace_refused detail)

let read_bytes ~send ~host ~port ~path =
  let ( let* ) = Result.bind in
  let* ()=match current_workspace_read () with
    | Some {wr_proof=Request_precondition;_} -> Ok ()
    | None | Some {wr_proof=Health_identity;_} ->
      Error "Binary reading requires an expected workspace request precondition" in
  let* path=workspace_read_path ~host ~port ~path in
  let* response=send ~path |> fun result -> Result.bind result validate_workspace_read_response in
  if Masc.Tui_decode.is_success_http_status response.Masc_http_client.status then Ok response.body
  else Error (Masc.Tui_decode.http_status_error ~status_code:response.status ~body:response.body)
