module S = Mcp_protocol.Sampling
module Store = Lane_addon_store
module Types = Lane_addon_types
let ( let* ) = Result.bind
type outcome =
  | Answer of S.create_message_result
  | Host_error of string
  | Invalid_response of S.create_message_result * string
  | Invocation_exception of string
type t = { package : Types.package; instance_id : string;
  handler : Agent_core.Mcp.sampling_handler }
let for_worker t ~package ~instance_id =
  if t.package = package && String.equal t.instance_id instance_id then Ok t.handler
  else Error "host sampling broker belongs to another package or installation"

type request_state = Pending | Finished of Types.evidence

exception Evidence_too_large

(* Check the wire size before Yojson allocates its complete buffer. This scan
   and encoding both run on a system thread. Escape widths follow Yojson's
   writer, including its DEL escape; scalar numeric encodings stay bounded. *)
let encode_bounded ~max_bytes json =
  let remaining = ref max_bytes in
  let consume n =
    if n > !remaining then raise Evidence_too_large;
    remaining := !remaining - n in
  let string value =
    consume 2;
    if String.length value > !remaining then raise Evidence_too_large;
    String.iter (fun c -> consume (match c with
      | '"' | '\\' | '\b' | '\012' | '\n' | '\r' | '\t' -> 2
      | '\x00' .. '\x1f' | '\x7f' -> 6 | _ -> 1)) value in
  let rec value = function
    | `String text -> string text
    | `Intlit text -> consume (String.length text)
    | `Null -> consume 4
    | `Bool true -> consume 4
    | `Bool false -> consume 5
    | (`Int _ | `Float _) as scalar -> consume (String.length (Yojson.Safe.to_string scalar))
    | `List items ->
        consume 2; sequence value items
    | `Assoc fields ->
        consume 2; sequence (fun (key, item) -> string key; consume 1; value item) fields
  and sequence : 'a. ('a -> unit) -> 'a list -> unit = fun write -> function
    | [] -> ()
    | first :: rest -> write first; List.iter (fun item -> consume 1; write item) rest in
  try value json; Ok (Yojson.Safe.to_string json)
  with Evidence_too_large -> Error "sampling evidence exceeds package byte envelope"

let create ~store ~(package : Types.package) ~instance_id ~route ~invoke () =
  let* () = match package.model_access with
    | Types.Host_sampling -> Ok ()
    | Types.Model_disabled -> Error "package does not declare host sampling" in
  let* () = if String.trim instance_id<>"" && String.trim route<>"" then Ok ()
    else Error "sampling requires an exact instance and nonblank host route" in
  let retain fields = Eio_unix.run_in_systhread (fun () ->
    let* bytes = encode_bounded ~max_bytes:package.resources.max_reply_bytes (`Assoc fields) in
    Store.write_blob store bytes) in
  let handler (params : S.create_message_params) =
    let* () = match params.include_context with
      | None | Some S.None_ -> Ok ()
      | Some S.ThisServer | Some S.AllServers -> Error "Lane sampling supplies its own context" in
    let* () = if params.max_tokens>0 then Ok () else Error "sampling requires a positive provider output limit" in
    let request_id = Random_id.prefixed ~prefix:"lane-model-" ~bytes:16 in
    let* request = retain ["kind",`String "model_request";
      "request_id",`String request_id;
      "instance_id",`String instance_id;"route",`String route;
      "package",`Assoc ["id",`String package.id;"revision",`String package.revision];
      "params",S.create_message_params_to_yojson params] in
    let record state =
      let state, outcome = match state with
        | Pending -> "pending", None | Finished evidence -> "finished", Some evidence in
      `Assoc ["request_id",`String request_id;
      "instance_id",`String instance_id;"route",`String route;
      "package",`Assoc ["id",`String package.id;"revision",`String package.revision];
      "state",`String state;"request",Types.evidence_to_json request;
      "outcome",Option.fold ~none:`Null ~some:Types.evidence_to_json outcome] in
    let save state = Eio_unix.run_in_systhread (fun () ->
      Store.save_sampling_request store ~instance_id ~request_id (record state)) in
    let* () = save Pending in
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
    let* () = match save (Finished evidence) with
      | Ok () -> Ok ()
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
          "error",`String detail;"evidence",references])) in
  Ok {package; instance_id; handler}
