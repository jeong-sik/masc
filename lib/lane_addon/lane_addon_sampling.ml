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
  try
    value json;
    let bytes = Yojson.Safe.to_string json in
    ignore (Yojson.Safe.from_string bytes);
    Ok bytes
  with
  | Evidence_too_large -> Error "sampling evidence exceeds package byte envelope"
  | Stack_overflow -> Error "sampling evidence nesting exceeds encoder capacity"
  | Yojson.Json_error _ | Invalid_argument _ -> Error "sampling evidence cannot be serialized"

let package_response (answer : S.create_message_result) = {answer with _meta=None}

let validate_response ~max_bytes answer =
  let* bytes = encode_bounded ~max_bytes (S.create_message_result_to_yojson answer) in
  try S.create_message_result_of_yojson (Yojson.Safe.from_string bytes) with
  | Stack_overflow -> Error "host response nesting exceeds parser capacity"
  | Yojson.Json_error _ -> Error "host response is not valid serialized JSON"
  | Not_found -> Error "host response has missing fields for its content discriminator"
  | Yojson.Safe.Util.Type_error (detail, _) -> Error detail

let create ~store ~(package : Types.package) ~instance_id ~route ~invoke () =
  let* () = match package.model_access with
    | Types.Host_sampling -> Ok ()
    | Types.Model_disabled -> Error "package does not declare host sampling" in
  let* () = if String.trim instance_id<>"" && String.trim route<>"" then Ok ()
    else Error "sampling requires an exact instance and nonblank host route" in
  let retain fields = Eio_unix.run_in_systhread (fun () ->
    let* bytes = encode_bounded ~max_bytes:package.resources.max_reply_bytes (`Assoc fields) in
    Store.write_blob store bytes)
    |> Result.map_error (fun _ -> "sampling request could not be retained") in
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
    let* () = save Pending |> Result.map_error (fun _ -> "sampling request could not be indexed") in
    let outcome = try match invoke ~route ~request params with
      | Ok answer ->
          (match Eio_unix.run_in_systhread (fun () ->
            validate_response ~max_bytes:package.resources.max_reply_bytes answer) with
           | Error detail -> Invalid_response (answer, detail)
           | Ok _ when String.trim answer.S.model = "" ->
               Invalid_response (answer, "host response has no model identity")
           | Ok _ -> Answer answer)
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
    (* Once invocation has returned, cancellation must not orphan a known
       result between its immutable blob and the durable recovery index. *)
    let retained = Eio.Cancel.protect (fun () ->
      Eio_unix.run_in_systhread (fun () ->
        let bytes = match encode_bounded ~max_bytes:package.resources.max_reply_bytes (`Assoc fields) with
          | Ok bytes -> Ok bytes
          | Error detail -> encode_bounded ~max_bytes:package.resources.max_reply_bytes
              (`Assoc ["kind",`String "model_outcome";"status",`String "retention_error";
                "request",Types.evidence_to_json request;"error",`String detail]) in
        let* bytes = Result.map_error (fun _ -> "sampling outcome could not be retained") bytes in
        let evidence = Store.blob_reference bytes in
        let terminal = match record (Finished evidence) with
          | `Assoc fields -> `Assoc (("outcome_bytes",`String bytes)::fields)
          | json -> json in
        (* Journal the complete outcome and link in the first durable write.
           Attempt both indexes even if one location is unavailable. *)
        let journal = Store.save_sampling_outcome store ~instance_id ~request_id terminal in
        let primary = Store.save_sampling_request store ~instance_id ~request_id terminal in
        let* () = match journal, primary with
          | Ok (), _ | _, Ok () -> Ok ()
          | Error _, Error _ -> Error "sampling outcome could not be indexed" in
        let* _ = Store.write_blob store bytes |> Result.map_error (fun _ ->
          "sampling outcome retained in recovery index") in
        Ok (`Assoc ["request",Types.evidence_to_json request;"outcome",Types.evidence_to_json evidence]))) in
    Eio.Fiber.check ();
    let* references = retained in
    match outcome with
    | Answer answer ->
        let answer = package_response answer in
        let response = {answer with _meta=Some (`Assoc ["masc.lane_sampling",references])} in
        let* () = Eio_unix.run_in_systhread (fun () ->
          encode_bounded ~max_bytes:package.resources.max_reply_bytes
            (S.create_message_result_to_yojson response) |> Result.map (fun _ -> ()))
          |> Result.map_error (fun _ -> "sampling response exceeds package byte envelope; retained outcome remains indexed") in
        Ok response
    | Host_error _ | Invalid_response _ | Invocation_exception _ ->
        let status = match outcome with
          | Host_error _ -> "host_error" | Invalid_response _ -> "invalid_response"
          | Invocation_exception _ -> "outcome_unknown" | Answer _ -> "answered" in
        let reply = `Assoc ["status",`String status;"evidence",references] in
        (match Eio_unix.run_in_systhread (fun () ->
           encode_bounded ~max_bytes:package.resources.max_reply_bytes reply) with
         | Ok bytes -> Error bytes
         | Error _ -> Error "sampling failed; outcome retained") in
  Ok {package; instance_id; handler}
