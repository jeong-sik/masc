module Async = Keeper_msg_async

let ( let* ) = Result.bind

type error =
  | Storage_failed of string
  | Invalid_obligation of string
  | Request_unavailable of Async.load_result
  | Canonical_result_unavailable of Async.canonical_terminal_error

let error_to_string = function
  | Storage_failed detail | Invalid_obligation detail -> detail
  | Canonical_result_unavailable error -> Async.canonical_terminal_error_to_string error
  | Request_unavailable (Async.Unreadable detail) -> detail
  | Request_unavailable Async.Absent -> "completion request is absent"
  | Request_unavailable (Async.Rejected error) -> Yojson.Safe.to_string (Async.access_rejection_to_json error)
  | Request_unavailable (Async.Found entry) -> "completion request has incompatible status " ^ Async.status_to_string entry.status
;;

type obligation = { request_id : string; keeper_name : string }
type pending = { base_path : string; keeper_name : string; request_id : string }
type discovery = { entries : pending list; failures : (string * error) list }

type report =
  { inspected : int
  ; waiting : int
  ; delivered : int
  ; failures : (string * error) list
  }

type record_outcome = Retired | Waiting | Delivered

let protect_io work =
  try work () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Storage_failed (Printexc.to_string exn))
;;

let directory ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "composition-completion-delivery"
;;

let pending_directory ~base_path = Filename.concat (directory ~base_path) "pending"
let filename request_id = Digestif.SHA256.(digest_string request_id |> to_hex) ^ ".json"
let path ~base_path request_id = Filename.concat (pending_directory ~base_path) (filename request_id)

let to_json (obligation : obligation) = `Assoc
  [ "schema", `String "keeper.composition_completion_obligation.v1"
  ; "request_id", `String obligation.request_id
  ; "keeper_name", `String obligation.keeper_name ]
;;

let of_json : Yojson.Safe.t -> (obligation, error) result = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)
        = [ "keeper_name"; "request_id"; "schema" ] ->
    (match List.assoc_opt "schema" fields, List.assoc_opt "request_id" fields,
           List.assoc_opt "keeper_name" fields with
     | Some (`String "keeper.composition_completion_obligation.v1"),
       Some (`String request_id), Some (`String keeper_name) -> Ok { request_id; keeper_name }
     | _ -> Error (Invalid_obligation "invalid completion obligation identity/schema"))
  | _ -> Error (Invalid_obligation "completion obligation requires its exact identity fields")
;;

let composition_tool (entry : Async.entry) =
  match entry.request_context with
  | Some fields ->
    (match List.assoc_opt "composition_tool" fields with
     | Some (`String tool) -> Ok tool
     | Some _ | None -> Error (Invalid_obligation "canonical request lacks composition producer identity"))
  | None -> Error (Invalid_obligation "canonical request lacks composition producer context")
;;

let prepare ~base_path ~keeper_name ~request_id ~composition_tool:tool =
  protect_io @@ fun () ->
  match Async.poll ~base_path ~caller:keeper_name request_id with
  | Async.Found ({ status = Async.Queued; _ } as entry)
      when String.equal entry.keeper_name keeper_name ->
    let* canonical_tool = composition_tool entry in
    if not (String.equal tool canonical_tool)
    then Error (Invalid_obligation "composition producer does not match its canonical request")
    else
      let base_path = entry.base_path in
      Keeper_fs.save_json_durable_atomic ~ownership_root:base_path
        ~temp_dir:(Filename.concat (directory ~base_path) ".atomic-staging") ~pretty:false
        (path ~base_path request_id) (to_json { request_id; keeper_name })
      |> Result.map_error (fun error -> Storage_failed (Keeper_fs.durable_write_error_to_string error))
  (* Only a queued request owned by this Keeper can become an obligation.
     Every other (status, keeper) pair is listed by constructor so that a new
     [Async.request_status] constructor or a new [load_result] constructor is
     reported here at compile time instead of silently inheriting this
     outcome. *)
  | Async.Found
      ({ status =
           ( Async.Queued | Async.Running | Async.Cancelling _ | Async.Lost _
           | Async.Cancelled _ | Async.Persistence_failed _ | Async.Done _
           | Async.Waiting_for_dependencies _ )
       ; _
       } as entry) ->
    Error (Request_unavailable (Async.Found entry))
  | Async.Absent -> Error (Request_unavailable Async.Absent)
  | Async.Unreadable reason -> Error (Request_unavailable (Async.Unreadable reason))
  | Async.Rejected rejection -> Error (Request_unavailable (Async.Rejected rejection))
;;

let read ~base_path name =
  let record_path = Filename.concat (pending_directory ~base_path) name in
  let* bytes = Fs_compat.load_owned_regular_file ~ownership_root:base_path record_path
    |> Result.map_error (fun error -> Storage_failed (Fs_compat.owned_regular_file_read_error_to_string error)) in
  match bytes with
  | None -> Ok None
  | Some raw ->
    let* obligation =
      try of_json (Yojson.Safe.from_string raw)
      with Yojson.Json_error detail -> Error (Invalid_obligation detail) in
    if String.equal name (filename obligation.request_id)
    then Ok (Some obligation)
    else Error (Invalid_obligation "completion obligation filename does not bind its request")
;;

let acknowledge ~base_path ~keeper_name ~request_id =
  protect_io @@ fun () ->
  let base_path = Fs_compat.realpath base_path in
  let* obligation = read ~base_path (filename request_id) in
  match obligation with
  | None -> Ok ()
  | Some obligation when String.equal obligation.request_id request_id
      && String.equal obligation.keeper_name keeper_name ->
    Keeper_fs.remove_file_durable ~ownership_root:base_path (path ~base_path request_id)
    |> Result.map_error (fun error -> Storage_failed (Keeper_fs.durable_remove_error_to_string error))
  | Some _ -> Error (Invalid_obligation "completion acknowledgement changed request/recipient identity")
;;

let acknowledge_waiting_with ~after_waiting_read ~base_path ~keeper_name ~request_id ~composition_tool:tool =
  let* outcome = Async.with_canonical_durable_terminal ~base_path ~caller:keeper_name request_id
      ~f:(fun proof ->
        let entry = Async.durable_terminal_entry proof in
        let* producer = composition_tool entry in
        if not (String.equal entry.keeper_name keeper_name && String.equal producer tool)
        then Error (Invalid_obligation "canonical waiting request changed its producer")
        else match entry.status with
          | Async.Waiting_for_dependencies _ ->
            after_waiting_read ();
            acknowledge ~base_path:entry.base_path ~keeper_name ~request_id
          | Queued | Running | Cancelling _ | Lost _ | Cancelled _
          | Persistence_failed _ | Done _ ->
            Error (Invalid_obligation "canonical request is not an owned-job waiting attempt"))
      |> Result.map_error (fun error -> Canonical_result_unavailable error) in
  outcome

let acknowledge_waiting = acknowledge_waiting_with ~after_waiting_read:(fun () -> ())

module For_testing = struct
  let acknowledge_waiting = acknowledge_waiting_with
end



let pending_names ~base_path =
  protect_io @@ fun () ->
  let base_path = Fs_compat.realpath base_path in
  let dir = pending_directory ~base_path in
  let* inspection = Fs_compat.inspect_owned_directory_chain ~ownership_root:base_path dir
    |> Result.map_error (fun error -> Storage_failed (Fs_compat.owned_directory_chain_rejection_to_string error)) in
  let names = match inspection with
    | Fs_compat.Owned_directory_missing -> []
    | Fs_compat.Owned_directory _ -> Fs_compat.read_dir dir in
  Ok (base_path, names)

let discover ~base_path =
  protect_io @@ fun () ->
  let* base_path, names = pending_names ~base_path in
  let entries, failures = List.fold_left (fun (entries, failures) name ->
    match protect_io (fun () -> read ~base_path name) with
    | Error error -> entries, (name, error) :: failures
    | Ok None -> entries, failures
    | Ok (Some (obligation : obligation)) ->
        let pending : pending =
          {base_path;keeper_name=obligation.keeper_name;request_id=obligation.request_id} in
        pending :: entries, failures) ([], []) names in
  Ok {entries=List.rev entries;failures=List.rev failures}

let recover_record ~base_path ~name ~expected ~deliver =
  protect_io (fun () ->
  let* obligation = read ~base_path name in
  match obligation with
  | None -> Ok Retired
  | Some obligation ->
    if (match expected with
      | None -> false
      | Some (original : pending) ->
          not (String.equal original.request_id obligation.request_id
            && String.equal original.keeper_name obligation.keeper_name))
    then Error (Invalid_obligation "pending completion changed its original request/recipient")
    else
    match Async.load_canonical_durable_terminal ~base_path ~caller:obligation.keeper_name obligation.request_id with
    | Error (Async.Canonical_terminal_runtime_active _ | Async.Canonical_terminal_nonterminal _) -> Ok Waiting
    (* The remaining terminal-load errors are listed by constructor: a new
       [Async.canonical_terminal_error] constructor must be classified here
       deliberately rather than caught by a catch-all. *)
    | Error
        (( Async.Canonical_terminal_absent
         | Async.Canonical_terminal_unreadable _
         | Async.Canonical_terminal_access_rejected _
         | Async.Canonical_terminal_publication_ambiguous _
         | Async.Canonical_terminal_noncanonical_location _ ) as error) ->
      Error (Canonical_result_unavailable error)
    | Ok proof ->
      let entry = Async.durable_terminal_entry proof in
      if not (String.equal entry.keeper_name obligation.keeper_name)
      then Error (Invalid_obligation "canonical result changed completion owner")
      else
        let* tool = composition_tool entry in
        let* recovery_pending = Keeper_tool_execution_journal.completion_pending ~base_path entry
            |> Result.map_error (fun error -> Storage_failed (Keeper_tool_execution_journal.error_to_string error)) in
        if recovery_pending then
          let* () = acknowledge ~base_path ~keeper_name:obligation.keeper_name ~request_id:entry.request_id in
          Ok Retired
        else
        match entry.status with
        | Async.Waiting_for_dependencies _ ->
          let* () = acknowledge_waiting ~base_path ~keeper_name:obligation.keeper_name
              ~request_id:entry.request_id ~composition_tool:tool in
          Ok Retired
        | Queued | Running | Cancelling _ | Lost _ | Cancelled _
        | Persistence_failed _ | Done _ ->
        let* () = deliver ~composition_tool:tool entry |> Result.map_error (fun detail -> Storage_failed detail) in
        let* () = acknowledge ~base_path ~keeper_name:obligation.keeper_name ~request_id:obligation.request_id in
        Ok Delivered)

let recover (pending : pending) ~deliver =
  recover_record ~base_path:pending.base_path ~name:(filename pending.request_id)
    ~expected:(Some pending) ~deliver

let flush ~base_path ~deliver =
  protect_io @@ fun () ->
  let* base_path, names = pending_names ~base_path in
  let empty = { inspected = 0; waiting = 0; delivered = 0; failures = [] } in
  let result = List.fold_left (fun report name ->
    let report = { report with inspected = report.inspected + 1 } in
    match recover_record ~base_path ~name ~expected:None ~deliver with
    | Ok Retired -> report
    | Ok Waiting -> { report with waiting = report.waiting + 1 }
    | Ok Delivered -> { report with delivered = report.delivered + 1 }
    | Error error -> { report with failures = (name, error) :: report.failures }) empty names in
  Ok { result with failures = List.rev result.failures }
;;
