module S = Mcp_protocol.Sampling
module Store = Lane_addon_store
module Types = Lane_addon_types
let ( let* ) = Result.bind
type outcome =
  | Answer of S.create_message_result
  | Host_error of string
  | Invalid_response of S.create_message_result * string
  | Invocation_exception of string
let create ~store ~(package : Types.package) ~instance_id ~route ~invoke () =
  let* () = match package.model_access with
    | Types.Host_sampling -> Ok ()
    | Types.Model_disabled -> Error "package does not declare host sampling" in
  let* () = if String.trim instance_id<>"" && String.trim route<>"" then Ok ()
    else Error "sampling requires an exact instance and nonblank host route" in
  let retain fields =
    let bytes = Yojson.Safe.to_string (`Assoc fields) in
    if String.length bytes>package.resources.max_reply_bytes
    then Error "sampling evidence exceeds package byte envelope"
    else Eio_unix.run_in_systhread (fun () -> Store.write_blob store bytes) in
  Ok (fun (params : S.create_message_params) ->
    let* () = match params.include_context with
      | None | Some S.None_ -> Ok ()
      | Some S.ThisServer | Some S.AllServers -> Error "Lane sampling supplies its own context" in
    let* () = if params.max_tokens>0 then Ok () else Error "sampling requires a positive provider output limit" in
    let* request = retain ["kind",`String "model_request";
      "request_id",`String (Random_id.prefixed ~prefix:"lane-model-" ~bytes:16);
      "instance_id",`String instance_id;"route",`String route;
      "package",`Assoc ["id",`String package.id;"revision",`String package.revision];
      "params",S.create_message_params_to_yojson params] in
    let outcome = try match invoke ~route ~request params with
      | Ok answer when String.trim answer.S.model<>"" -> Answer answer
      | Ok answer -> Invalid_response (answer, "host response has no model identity")
      | Error detail -> Host_error detail
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Invocation_exception (Printexc.to_string exn) in
    let fields = ["kind",`String "model_outcome";"instance_id",`String instance_id;
      "route",`String route;"request",Types.evidence_to_json request] in
    let fields = fields @ (match outcome with
      | Answer answer -> ["status",`String "answered";"response",S.create_message_result_to_yojson answer]
      | Host_error detail -> ["status",`String "host_error";"error",`String detail]
      | Invalid_response (answer, detail) -> ["status",`String "invalid_response";
          "error",`String detail;"response",S.create_message_result_to_yojson answer]
      | Invocation_exception detail -> ["status",`String "outcome_unknown";"error",`String detail]) in
    let* evidence = match retain fields with
      | Ok evidence -> Ok evidence
      | Error detail -> Error (Yojson.Safe.to_string (`Assoc ["status",`String "outcome_unknown";
          "error",`String detail;"request",Types.evidence_to_json request])) in
    let references = `Assoc ["request",Types.evidence_to_json request;"outcome",Types.evidence_to_json evidence] in
    match outcome with
    | Answer answer ->
        let metadata = match answer.S._meta with Some (`Assoc fields) -> fields | _ -> [] in
        Ok {answer with _meta=Some (`Assoc (("masc.lane_sampling",references)
          :: List.filter (fun (key, _) -> not (String.equal key "masc.lane_sampling")) metadata))}
    | Host_error detail ->
        Error (Yojson.Safe.to_string (`Assoc ["status",`String "host_error";
          "error",`String detail;"evidence",references]))
    | Invalid_response (_, detail) ->
        Error (Yojson.Safe.to_string (`Assoc ["status",`String "invalid_response";
          "error",`String detail;"evidence",references]))
    | Invocation_exception detail ->
        Error (Yojson.Safe.to_string (`Assoc ["status",`String "outcome_unknown";
          "error",`String detail;"evidence",references])))
