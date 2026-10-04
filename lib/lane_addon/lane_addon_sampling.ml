module S = Mcp_protocol.Sampling
module Store = Lane_addon_store
module Types = Lane_addon_types
let ( let* ) = Result.bind
type outcome =
  | Answer of S.create_message_result
  | Host_error of string
  | Invalid_response of S.create_message_result * string
  | Invocation_exception of string
type observation = Outside_observation | Observing of string
type t = { package : Types.package; instance_id : string; store : Store.t;
  observation : observation ref;
  handler : Agent_core.Mcp.sampling_handler }
let for_worker t ~package ~instance_id =
  if t.package = package && String.equal t.instance_id instance_id then Ok t.handler
  else Error "host sampling broker belongs to another package or installation"

let with_observation t ~binding ~sources ~on_error run =
  let digest = Eio_unix.run_in_systhread (fun () ->
    Store.digest (Yojson.Safe.to_string (`Assoc ["binding",binding;"sources",sources]))) in
  match !(t.observation) with
  | Observing _ -> Error (on_error "host sampling observation already active")
  | Outside_observation ->
      t.observation := Observing digest;
      Fun.protect ~finally:(fun () -> t.observation := Outside_observation) (fun () ->
        let* (output : Types.output) = run () in
        let* () = Eio_unix.run_in_systhread (fun () ->
          let budget = Store.read_budget ~max_bytes:t.package.resources.max_reply_bytes in
          List.fold_left (fun result (reference : Types.evidence) ->
            let* () = result in
            (* Other evidence may be arbitrary bytes. Only this broker's own
               model requests attest computation on its current inputs. *)
            match Store.read_blob_bounded ~budget t.store reference with
            | Error Store.Read_limit_exceeded -> Error "sampling observation evidence exceeds aggregate read envelope"
            | Error (Store.Read_failed _) -> Ok ()
            | Ok bytes ->
                let json = try Some (Yojson.Safe.from_string bytes)
                  with Yojson.Json_error _ -> None in
                match json with
                | Some (`Assoc fields)
                  when List.assoc_opt "kind" fields = Some (`String "model_request")
                    && List.assoc_opt "instance_id" fields = Some (`String t.instance_id) ->
                    if List.assoc_opt "observation_inputs_sha256" fields = Some (`String digest)
                    then Ok () else Error "model evidence belongs to different observation inputs"
                | Some _ | None -> Ok ()) (Ok ())
            (List.concat_map (fun (row : Types.row) -> row.evidence) output.rows
             |> List.sort_uniq Stdlib.compare)) |> Result.map_error on_error in
        Ok output)

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
    | `Float value when not (Float.is_finite value) ->
        invalid_arg "sampling evidence contains a non-finite number"
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
    let bytes = Yojson.Safe.to_string ~std:true json in
    ignore (Yojson.Safe.from_string bytes);
    Ok bytes
  with
  | Evidence_too_large -> Error "sampling evidence exceeds package byte envelope"
  | Stack_overflow -> Error "sampling evidence nesting exceeds encoder capacity"
  | Yojson.Json_error _ | Invalid_argument _ -> Error "sampling evidence cannot be serialized"

let package_response (answer : S.create_message_result) = {answer with _meta=None}

let response_with_references (answer : S.create_message_result) references =
  let answer = package_response answer in
  {answer with _meta=Some (`Assoc ["masc.lane_sampling",references])}

let encode_sampling_reply ~request_id ~max_bytes reply =
  match request_id with
  | None ->
      let json = match reply with
        | Ok answer -> S.create_message_result_to_yojson answer
        | Error message -> `String message in
      encode_bounded ~max_bytes json
  | Some id ->
      let module J = Mcp_protocol.Jsonrpc in
      let frame = match reply with
        | Ok answer -> J.make_response ~id ~result:(S.create_message_result_to_yojson answer)
        | Error message -> J.make_error ~id ~code:Mcp_protocol.Error_codes.internal_error ~message () in
      encode_bounded ~max_bytes:(max_bytes - 1) (J.message_to_yojson frame)

let bound_refusal ~max_bytes message =
  let json_len s = String.length (Yojson.Safe.to_string (`String s)) in
  (* MCP serializes every refusal as a JSON string, including a structured
     receipt carried inside that string. Its quotes must fit too. *)
  if String.length message <= max_bytes && json_len message <= max_bytes then message
  else
    let refusal = "sampling failed; outcome retained" in
    if json_len refusal <= max_bytes then refusal
    else
      let compact = "refused" in
      if json_len compact <= max_bytes then compact
      else
        let max_content = max 0 (max_bytes - 2) in
        String.sub compact 0 (min (String.length compact) max_content)

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
  let observation = ref Outside_observation in
  let handler ?request_id:wire_id (params : S.create_message_params) =
    let run () =
    let* observation_inputs = match !observation with
      | Outside_observation -> Error "host sampling requires an active observation"
      | Observing digest -> Ok (`String digest) in
    let* () = match params.include_context with
      | None | Some S.None_ -> Ok ()
      | Some S.ThisServer | Some S.AllServers -> Error "Lane sampling supplies its own context" in
    let* () = if params.max_tokens>0 then Ok () else Error "sampling requires a positive provider output limit" in
    let request_id = Random_id.prefixed ~prefix:"lane-model-" ~bytes:16 in
    let* request = retain ["kind",`String "model_request";
      "request_id",`String request_id;
      "instance_id",`String instance_id;"route",`String route;
      "observation_inputs_sha256",observation_inputs;
      "package",`Assoc ["id",`String package.id;"revision",`String package.revision];
      "params",S.create_message_params_to_yojson params] in
    let* () = match wire_id with
      | None -> Ok ()
      | Some _ ->
          let references = `Assoc ["request",Types.evidence_to_json request;
            "outcome",Types.evidence_to_json request] in
          let reply = Yojson.Safe.to_string (`Assoc ["status",`String "invalid_response";
            "evidence",references]) in
          encode_sampling_reply ~request_id:wire_id
            ~max_bytes:package.resources.max_reply_bytes (Error reply)
          |> Result.map (fun _ -> ()) in
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
      | Ok answer -> Answer answer
      | Error detail -> Host_error detail
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Invocation_exception (Printexc.to_string exn) in
    (* No yielding operation may separate the returned outcome from protection. *)
    let retained = Eio.Cancel.protect (fun () ->
    let outcome = match outcome with
      | Answer answer ->
          (match Eio_unix.run_in_systhread (fun () ->
            validate_response ~max_bytes:package.resources.max_reply_bytes answer) with
           | Error detail -> Invalid_response (answer, detail)
           | Ok _ when String.trim answer.S.model = "" ->
               Invalid_response (answer, "host response has no model identity")
           | Ok _ -> Answer answer)
      | outcome -> outcome in
    let fields = ["kind",`String "model_outcome";"instance_id",`String instance_id;
      "route",`String route;"request",Types.evidence_to_json request] in
    let identity = fields in
    let fields = fields @ (match outcome with
      | Answer answer -> ["status",`String "answered";"response",S.create_message_result_to_yojson answer]
      | Host_error detail -> ["status",`String "host_error";"error",`String detail]
      | Invalid_response (answer, detail) -> ["status",`String "invalid_response";
          "error",`String detail;"response",S.create_message_result_to_yojson answer]
      | Invocation_exception detail -> ["status",`String "outcome_unknown";"error",`String detail]) in
    (* Once invocation has returned, cancellation must not orphan a known
       result between its immutable blob and the durable recovery index. *)
    let retained = Eio_unix.run_in_systhread (fun () ->
        let outcome, bytes = match encode_bounded ~max_bytes:package.resources.max_reply_bytes (`Assoc fields) with
          | Ok bytes -> outcome, Ok bytes
          | Error detail ->
              let outcome = match outcome with
                | Answer answer -> Invalid_response (answer, detail)
                | outcome -> outcome in
              let status = match outcome with
                | Answer _ -> "answered" | Host_error _ -> "host_error"
                | Invalid_response _ -> "invalid_response"
                | Invocation_exception _ -> "outcome_unknown" in
              outcome, encode_bounded ~max_bytes:package.resources.max_reply_bytes
                (`Assoc (identity @ ["status",`String status;"error",`String detail])) in
        let* bytes = Result.map_error (fun _ -> "sampling outcome could not be retained") bytes in
        let* outcome, bytes = match outcome with
          | Answer answer ->
              let references = `Assoc ["request",Types.evidence_to_json request;
                "outcome",Types.evidence_to_json (Store.blob_reference bytes)] in
              (match encode_sampling_reply ~request_id:wire_id ~max_bytes:package.resources.max_reply_bytes
                  (Ok (response_with_references answer references)) with
               | Ok _ -> Ok (outcome, bytes)
               | Error detail ->
                   let invalid_fields = identity @
                     ["status",`String "invalid_response";"error",`String detail] in
                   let bytes = encode_bounded ~max_bytes:package.resources.max_reply_bytes
                     (`Assoc (invalid_fields @
                       ["response",S.create_message_result_to_yojson answer])) in
                   let* bytes = match bytes with
                     | Ok bytes -> Ok bytes
                     | Error _ -> encode_bounded ~max_bytes:package.resources.max_reply_bytes
                         (`Assoc invalid_fields) in
                   Ok (Invalid_response (answer, detail), bytes))
          | Host_error _ | Invalid_response _ | Invocation_exception _ -> Ok (outcome, bytes) in
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
        let references = `Assoc ["request",Types.evidence_to_json request;
          "outcome",Types.evidence_to_json evidence] in
        let* _ = Store.write_sampling_blob store bytes |> Result.map_error (fun _ ->
          match encode_bounded ~max_bytes:package.resources.max_reply_bytes
            (`Assoc ["status",`String "retention_error";"evidence",references]) with
          | Ok bytes -> bytes
          | Error _ -> "sampling outcome retained in recovery index") in
        let compact = record (Finished evidence) in
        ignore (Store.save_sampling_outcome store ~instance_id ~request_id compact);
        ignore (Store.save_sampling_request store ~instance_id ~request_id compact);
        Ok (outcome, references)) in
    retained) in
    Eio.Fiber.check ();
    let* outcome, references = retained in
    match outcome with
    | Answer answer ->
        Ok (response_with_references answer references)
    | Host_error _ | Invalid_response _ | Invocation_exception _ ->
        let status = match outcome with
          | Host_error _ -> "host_error" | Invalid_response _ -> "invalid_response"
          | Invocation_exception _ -> "outcome_unknown" | Answer _ -> "answered" in
        let reply = `Assoc ["status",`String status;"evidence",references] in
        (match Eio_unix.run_in_systhread (fun () ->
           encode_bounded ~max_bytes:package.resources.max_reply_bytes reply) with
         | Ok bytes -> Error bytes
         | Error _ -> Error "sampling failed; outcome retained") in
    run () |> Result.map_error (fun message ->
      match wire_id with
      | None -> bound_refusal ~max_bytes:package.resources.max_reply_bytes message
      | Some _ ->
          match encode_sampling_reply ~request_id:wire_id
              ~max_bytes:package.resources.max_reply_bytes (Error message) with
          | Ok _ -> message
          | Error _ ->
              let empty_size = match encode_sampling_reply ~request_id:wire_id
                  ~max_bytes:max_int (Error "") with
                | Ok bytes -> String.length bytes + 1
                | Error _ -> package.resources.max_reply_bytes in
              let available = max 0 (package.resources.max_reply_bytes - empty_size) in
              let refusal = "sampling failed; outcome retained" in
              String.sub refusal 0 (min available (String.length refusal))) in
  Ok {package; instance_id; store; observation; handler}

let retained_receipts ~store ~instance_id ~max_bytes (output : Types.output) =
  let budget = Store.read_budget ~max_bytes in
  let read_error = function
    | Store.Read_limit_exceeded -> "sampling receipts exceed aggregate read envelope"
    | Store.Read_failed detail -> detail in
  let member key = function `Assoc fields -> List.assoc_opt key fields | _ -> None in
  let same key expected json = member key json = Some (`String expected) in
  let package_terminal = function
    | `Assoc fields -> `Assoc (List.map (function
        | "response",`Assoc response -> "response",`Assoc (List.remove_assoc "_meta" response)
        | field -> field) (List.remove_assoc "error" fields))
    | json -> json in
  (* An outcome is both row evidence and a request's terminal. Resolve each
     immutable address once so those two paths share the actual read charge. *)
  let blobs = Hashtbl.create 8 in
  let read_blob reference =
    match Hashtbl.find_opt blobs reference with
    | Some result -> result
    | None ->
        let result = Store.read_blob_bounded ~budget store reference in
        (* An outcome may be visited before its request restores the journaled
           bytes. Cache successful reads and exhausted budgets, never absence
           or a failed publication that the request read can repair. *)
        (match result with
         | Ok _ | Error Store.Read_limit_exceeded -> Hashtbl.add blobs reference result
         | Error (Store.Read_failed _) -> ());
        result in
  let json_bytes reference =
    match read_blob reference with
    | Error Store.Read_limit_exceeded -> Error (read_error Store.Read_limit_exceeded)
    | Error (Store.Read_failed _) -> Ok None
    | Ok bytes -> Ok (try Some (Yojson.Safe.from_string bytes) with Yojson.Json_error _ -> None) in
  let receipt reference =
    let* request = json_bytes reference in
    match request with
    | Some request when same "kind" "model_request" request && same "instance_id" instance_id request ->
        (match member "request_id" request with
         | Some (`String request_id) ->
             let* record = Store.load_sampling_request_bounded ~budget store ~instance_id ~request_id
               |> Result.map_error read_error in
             (match record with
              | Some record when same "instance_id" instance_id record
                  && same "request_id" request_id record
                  && member "request" record = Some (Types.evidence_to_json reference) ->
                  (match member "state" record, member "outcome" record with
                   | Some (`String "pending"), Some `Null ->
                       Ok (Some (`Assoc ["request",Types.evidence_to_json reference;
                         "outcome",`Null;"terminal",`Null]))
                   | Some (`String "finished"), Some outcome ->
                       let* outcome_ref = Types.evidence_of_json outcome in
                       (match member "outcome_bytes" record with
                        | Some (`String bytes) ->
                            (* The bounded store reader verified this digest
                               and already charged these journal bytes. *)
                            Hashtbl.replace blobs outcome_ref (Ok bytes)
                        | _ -> ());
                       let* bytes = read_blob outcome_ref
                         |> Result.map_error read_error in
                       let* terminal = try Ok (Yojson.Safe.from_string bytes)
                         with Yojson.Json_error error -> Error error in
                       if same "kind" "model_outcome" terminal && same "instance_id" instance_id terminal
                           && member "request" terminal = Some (Types.evidence_to_json reference)
                       then Ok (Some (`Assoc ["request",Types.evidence_to_json reference;
                         "outcome",outcome;"terminal",package_terminal terminal]))
                       else Error "retained sampling outcome contradicts its host request"
                   | _ -> Error "invalid host sampling receipt")
              | _ -> Ok None)
         | _ -> Ok None)
    | _ -> Ok None in
  let references = List.concat_map (fun (row : Types.row) -> row.evidence) output.rows
    |> List.sort_uniq Stdlib.compare in
  let* receipts, _ = List.fold_left (fun result reference ->
    let* receipts, remaining = result in
    let* captured = receipt reference in
    match captured with
    | None -> Ok (receipts, remaining)
    | Some value ->
        let size = String.length (Yojson.Safe.to_string value) in
        if size > remaining then Error "sampling receipts exceed the source envelope"
        else Ok (value :: receipts, remaining - size)) (Ok ([],max_bytes)) references in
  Ok receipts
