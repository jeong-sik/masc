module Client = Typesafeai_client
module Types = Typesafeai_types

type t =
  { selection_id : string
  ; path : string
  ; destinations : Typesafeai_config.destinations
  ; mutable request_ids_rev : string list
  }

let create ~config ~keeper_id ~destinations =
  let directory = Filename.concat (Workspace.keepers_runtime_dir config) keeper_id in
  { selection_id=Random_id.prefixed ~prefix:"memory-selection-set-" ~bytes:16;
    path=Filename.concat directory "memory-selection-evaluations.jsonl";
    destinations;request_ids_rev=[] }

let selection_id t = t.selection_id
let request_ids t = List.rev t.request_ids_rev
let journal_path t = t.path

let append_unprotected t row =
  let payload = Yojson.Safe.to_string row ^ "\n" in
  match Fs_compat.append_private_jsonl_durable_locked_result t.path payload with
  | Fs_compat.Private_file_succeeded () -> Ok ()
  | Fs_compat.Private_file_succeeded_with_cleanup_failure {value=();cleanup_failure} ->
    Log.Keeper.warn "memory selection record committed; descriptor cleanup failed: %s"
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
    Ok ()
  | Fs_compat.Private_file_failed error ->
    Error (Fs_compat.private_jsonl_append_error_to_string error)
  | Fs_compat.Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
    Error (Printf.sprintf "%s; descriptor cleanup failed: %s"
      (Fs_compat.private_jsonl_append_error_to_string error)
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))

let append t row =
  try Domain_pool_ref.submit_io_or_inline (fun () -> append_unprotected t row) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error detail -> Error detail
  | Unix.Unix_error (code,operation,path) ->
    Error (Printf.sprintf "%s(%s): %s" operation path (Unix.error_message code))

let retain_result t ~purpose result =
  let outcome = match result with
    | Ok result -> `Assoc ["result",result]
    | Error detail -> `Assoc ["unavailable",`String detail] in
  append t (`Assoc ["selection_id",`String t.selection_id;
                   "status",`String "selection_completed";
                   "recorded_at",`Float (Time_compat.now ());
                   "purpose",purpose;"outcome",outcome])

let retain_projection t ~reason ~payload =
  append t (`Assoc ["selection_id",`String t.selection_id;
                   "status",`String "delivery_projection_prepared";
                   "recorded_at",`Float (Time_compat.now ());
                   "reason",`String reason;"payload",payload])

let response_json (evaluated : Client.evaluated) =
  `Assoc
    ["destination",Client.destination_id_to_yojson evaluated.destination;
     "request_body_sha256",`String evaluated.request_body_sha256;
     "passed_over",`List (List.map Client.attempt_to_yojson evaluated.passed_over);
     "model",`String evaluated.response.model;
     "answers",`Assoc (List.map (fun (id,answer) -> id,Types.answer_to_yojson answer)
       evaluated.response.answers);
     "usage",(match evaluated.response.usage with
       | None -> `Null
       | Some usage -> `Assoc ["input_tokens",`Int usage.input_tokens;
                               "output_tokens",`Int usage.output_tokens])]

let evaluate_with ~call t ~state ~questions =
  let request_id = Random_id.prefixed ~prefix:"memory-selection-" ~bytes:16 in
  let row fields = `Assoc (["selection_id",`String t.selection_id;
                            "request_id",`String request_id;
                            "recorded_at",`Float (Time_compat.now ())] @ fields) in
  let first,rest = t.destinations in
  let started = row
    ["status",`String "started";
     "destinations",`List (List.map (fun destination ->
       Client.destination_id_to_yojson (Client.identify destination)) (first::rest));
     "state",state;
     "questions",`Assoc (List.map (fun (id,question) ->
       id,Types.question_to_yojson question) questions)] in
  match append t started with
  | Error detail -> Error (Keeper_workspace_memory_selection.Unavailable ("selection input persistence failed: " ^ detail))
  | Ok () ->
    t.request_ids_rev <- request_id :: t.request_ids_rev;
    let result =
      try call ~destinations:t.destinations ~state ~questions () with
      | Eio.Cancel.Cancelled _ as exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        Eio.Cancel.protect (fun () ->
          match append t (row ["status",`String "cancelled"]) with
          | Ok () -> ()
          | Error _ -> Log.Keeper.warn
              "memory selection cancellation receipt unavailable request=%s" request_id);
        Printexc.raise_with_backtrace exn backtrace
    in
    let completion = match result with
      | Error failure -> row ["status",`String "provider_failed";
                              "failure",Client.failure_to_yojson failure]
      | Ok evaluated -> row ["status",`String "response_received";
                              "response",response_json evaluated] in
    (match append t completion with
     | Error detail -> Error (Keeper_workspace_memory_selection.Unavailable ("selection response persistence failed: " ^ detail))
     | Ok () -> result |> Result.map (fun evaluated -> evaluated.Client.response)
         |> Result.map_error (fun failure ->
           let detail = Client.failure_to_string failure in
           match Client.failure_kind failure with
           | Client.Capacity_refused -> Keeper_workspace_memory_selection.Capacity_refused detail
           | Other_refusal -> Keeper_workspace_memory_selection.Unavailable detail))

let evaluate ?clock t ~state ~questions =
  evaluate_with ~call:(fun ~destinations ~state ~questions () ->
    Client.evaluate ?clock ~destinations ~state ~questions ()) t ~state ~questions

module For_testing = struct
  let evaluate_with = evaluate_with
end
