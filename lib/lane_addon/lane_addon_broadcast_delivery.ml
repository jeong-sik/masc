module Request_id = Keeper_chat_delivery_identity.Request_id
let ( let* ) = Result.bind
type t = {root : string; io : Fs_compat.private_jsonl_transaction_io_for_testing option}
type recipient_state = Pending of string option | Accepted
type workspace_state = Uncommitted | Committed of int
type sender_authority = Keeper_sender | External_sender
let sender_snapshot ~caller ~access ~registered =
  let module Id = Keeper_identity.Keeper_id in
  let parse name = match Id.of_string name with
    | Some id -> Ok id | None -> Error "Fleet identity must not be blank" in
  let* registered = List.fold_left (fun result name ->
    let* names = result in
    let* id = parse name in
    Ok ((id,name)::names)) (Ok []) registered in
  (* Compare canonical identities, retaining the registry's actual name for
     delivery to its durable path. Case aliases must not duplicate fanout. *)
  let registered = List.sort_uniq (fun (a,_) (b,_) -> Id.compare a b) registered in
  let names entries = List.map snd entries in
  match access with
  | Lane_addon_sources.Operator_configuration -> Ok (External_sender,names registered)
  | Lane_addon_sources.Keeper keeper ->
      let* keeper = parse keeper in
      let* caller = parse caller in
      if not (Id.equal keeper caller) then Error "Fleet sender lacks verified authority"
      else if List.exists (fun (id,_) -> Id.equal id keeper) registered
      then Ok (Keeper_sender,names (List.filter (fun (id,_) -> not (Id.equal id keeper)) registered))
      else Ok (External_sender,names registered)
  | Lane_addon_sources.Unauthenticated -> Error "Fleet sender lacks verified authority"
type payload = {sender_authority:sender_authority;caller:string;operation_id:Request_id.t;artifact_sha256:string;
                content:string;recipients:string list}
type record = {payload:payload;workspace_request_id:Request_id.t;
               workspace:workspace_state;recipients:(string * recipient_state) list}
type error = Invalid_input of string | Conflict | Unknown_operation | Corrupt of string | Io_error of string
  | Settlement_failed of {primary:error;cleanup:string}
type receipt = {record:record;settlement_error:string option}
type recovery = {pending:receipt list;settled_with_cleanup:receipt list;rejected:(string * error) list}
let create ~root = {root;io=None}
let transaction t path decide = match t.io with
  | None -> Fs_compat.update_private_file_durable_locked_result path decide
  | Some io -> Fs_compat.update_private_file_durable_locked_with_io_for_testing ~io path decide
let existing_transaction t path decide = match t.io with
  | None -> Fs_compat.update_existing_private_file_durable_locked_result path decide
  | Some io -> Fs_compat.update_existing_private_file_durable_locked_with_io_for_testing ~io path decide
let valid_digest value = String.length value=64 && String.for_all
  (function '0'..'9' | 'a'..'f' -> true | _ -> false) value
let validate (p : payload) =
  if String.trim p.caller="" || String.trim p.content="" then Error (Invalid_input "caller and content are required")
  else if not (valid_digest p.artifact_sha256) then Error (Invalid_input "artifact SHA-256 is required")
  else if List.exists (fun name -> String.trim name="") p.recipients
    || List.length p.recipients <> List.length (List.sort_uniq String.compare p.recipients)
  then Error (Invalid_input "recipient snapshot must contain unique nonblank names") else Ok ()
let identity caller operation_id = Lane_addon_store.digest (Yojson.Safe.to_string
  (`List [`String caller;`String (Request_id.to_string operation_id)]))
let path t caller operation_id = Filename.concat t.root (identity caller operation_id ^ ".jsonl")
let request_id p = Request_id.of_string ("wmsg-" ^ String.sub (identity p.caller p.operation_id) 0 32)
  |> Result.map_error (fun e -> Invalid_input e)
let exact keys = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare keys -> Ok fields
  | _ -> Error (Corrupt "unknown, duplicate or missing event field")
let text fields key = match List.assoc key fields with
  | `String s -> Ok s | _ -> Error (Corrupt (key ^ " must be text"))
let authority_json = function Keeper_sender -> `String "keeper" | External_sender -> `String "external"
let event_payload p = `Assoc ["event",`String "admitted";"sender_authority",authority_json p.sender_authority;"caller",`String p.caller;
  "operation_id",`String (Request_id.to_string p.operation_id);
  "artifact_sha256",`String p.artifact_sha256;"content",`String p.content;
  "recipients",`List (List.map (fun v -> `String v) p.recipients)]
let initial json =
  let* f = exact ["event";"sender_authority";"caller";"operation_id";"artifact_sha256";"content";"recipients"] json in
  let* event = text f "event" in
  if event<>"admitted" then Error (Corrupt "first event must admit a delivery") else
  let* sender_authority=match List.assoc "sender_authority" f with
    | `String "keeper" -> Ok Keeper_sender | `String "external" -> Ok External_sender
    | _ -> Error (Corrupt "unknown sender authority") in
  let* caller = text f "caller" in let* operation = text f "operation_id" in
  let* operation_id = Request_id.of_string operation |> Result.map_error (fun e -> Corrupt e) in
  let* artifact_sha256 = text f "artifact_sha256" in let* content = text f "content" in
  let* recipients = match List.assoc "recipients" f with
    | `List names -> List.fold_right (fun value acc -> let* rest=acc in match value with
        | `String name -> Ok (name::rest) | _ -> Error (Corrupt "recipient must be text")) names (Ok [])
    | _ -> Error (Corrupt "recipients must be a list") in
  let payload = {sender_authority;caller;operation_id;artifact_sha256;content;recipients} in
  let* () = validate payload |> Result.map_error (function Invalid_input e -> Corrupt e | e -> e) in
  let* workspace_request_id = request_id payload in
  Ok {payload;workspace_request_id;workspace=Uncommitted;
      recipients=List.map (fun name -> name,Pending None) recipients}
let transition record json =
  match json with
  | `Assoc f -> (match List.assoc_opt "event" f with
      | Some (`String "committed") ->
          let* f = exact ["event";"seq"] json in
          (match List.assoc "seq" f,record.workspace with
           | `Int seq,Uncommitted when seq>0 -> Ok {record with workspace=Committed seq}
           | `Int seq,Committed previous when seq=previous -> Ok record
           | _ -> Error (Corrupt "contradictory workspace commit"))
      | Some (`String "recipient") ->
          let* f = exact ["event";"recipient";"state";"error"] json in
          let* recipient=text f "recipient" in let* state=text f "state" in
          let* next = match state,List.assoc "error" f with
            | "accepted",`Null -> Ok Accepted
            | "pending",`Null -> Ok (Pending None)
            | "pending",`String detail -> Ok (Pending (Some detail))
            | _ -> Error (Corrupt "invalid recipient state") in
          (match record.workspace,List.assoc_opt recipient record.recipients,next with
           | Committed _,Some (Pending (Some _)),Pending None ->
               Error (Corrupt "pending update cannot erase failed-attempt evidence")
           | Committed _,Some (Pending _),_ | Committed _,Some Accepted,Accepted ->
               Ok {record with recipients=List.map (fun (name,old) ->
                 name,(if name=recipient then next else old)) record.recipients}
           | _ -> Error (Corrupt "recipient not admitted, commit absent or accepted state regressed"))
      | Some _ | None -> Error (Corrupt "unknown delivery event"))
  | _ -> Error (Corrupt "delivery event must be an object")
let decode bytes =
  try
  if bytes="" then Ok None else
  if bytes.[String.length bytes-1]<>'\n' then Error (Corrupt "incomplete delivery journal") else
  match List.rev (String.split_on_char '\n' bytes) with
  | ""::reversed -> (match List.rev reversed with
  | [] -> Error (Corrupt "empty delivery journal")
  | first::rest ->
      let* record=initial (Yojson.Safe.from_string first) in
      List.fold_left (fun acc line -> let* record=acc in transition record (Yojson.Safe.from_string line))
        (Ok record) rest |> Result.map Option.some)
  | _ -> Error (Corrupt "incomplete delivery journal")
  with Yojson.Json_error detail -> Error (Corrupt detail)
let protect f = try f () with
  | Sys_error e -> Error (Io_error e)
  | Unix.Unix_error (e,call,arg) -> Error (Io_error (call ^ " " ^ arg ^ ": " ^ Unix.error_message e))
  | Yojson.Json_error e -> Error (Corrupt e)
let complete r = match r.workspace with
  | Uncommitted -> false
  | Committed _ -> List.for_all (function _,Accepted -> true | _,Pending _ -> false) r.recipients
let pending_dir t = Filename.concat t.root "pending"
let marker t filename = Filename.concat (pending_dir t) (Filename.basename filename)
let sync_directory directory =
  let fd=Unix.openfile directory [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
let ensure_pending t filename =
  Fs_compat.save_file_atomic_strict (marker t filename) ""
  |> Result.map_error (fun detail -> Io_error detail)
let remove_marker t filename = protect (fun () ->
  (try Unix.unlink (marker t filename) with Unix.Unix_error (Unix.ENOENT,_,_) -> ());
  sync_directory (pending_dir t); Ok ())
let settle_marker t filename receipt =
  if not (complete receipt.record) then receipt else
  match remove_marker t filename with
  | Ok () -> receipt
  | Error error ->
      let detail=match error with Io_error detail -> detail | _ -> "pending index cleanup failed" in
      {receipt with settlement_error=Some (match receipt.settlement_error with
        | None -> detail | Some previous -> previous ^ "; " ^ detail)}
type transaction_mode = Admit_operation | Update_operation
let map_transaction_outcome ~value ~error = function
  | Fs_compat.Private_file_succeeded result ->
      Fs_compat.Private_file_succeeded (value result)
  | Fs_compat.Private_file_succeeded_with_cleanup_failure {value=result;cleanup_failure} ->
      Fs_compat.Private_file_succeeded_with_cleanup_failure {value=value result;cleanup_failure}
  | Fs_compat.Private_file_failed primary ->
      Fs_compat.Private_file_failed (error primary)
  | Fs_compat.Private_file_failed_with_cleanup_failure {error=primary;cleanup_failure} ->
      Fs_compat.Private_file_failed_with_cleanup_failure {error=error primary;cleanup_failure}
let transact t ~mode ~caller ~operation_id decide =
  if String.trim caller="" then Error (Invalid_input "authenticated caller is required") else protect (fun () ->
  let filename=path t caller operation_id in
  let decide_rows bytes = match decode bytes with
    | Error e -> None,Error e
    | Ok existing ->
        let checked=match existing with
          | Some record when record.payload.caller<>caller
              || not (Request_id.equal record.payload.operation_id operation_id) -> Error Conflict
          | _ -> decide existing in
        match checked with
        | Error e -> None,Error e
        | Ok (event,record) ->
            (* Persist discoverability before appending any pending intention. *)
            let indexed=if complete record then Ok () else ensure_pending t filename in
            (match indexed with
             | Error error -> None,Error error
             | Ok () -> Option.map (fun json -> Yojson.Safe.to_string json ^ "\n") event,Ok record) in
  let outcome=match mode with
    | Admit_operation ->
        Fs_compat.mkdir_p (pending_dir t); sync_directory t.root;
        transaction t filename decide_rows
        |> map_transaction_outcome ~value:Fun.id
          ~error:(fun e -> Io_error (Fs_compat.durable_append_error_to_string e))
    | Update_operation ->
        (* Missing journals are not admission: open without O_CREAT, and validate
           the opened binding while holding the writer lock before deciding. *)
        let existing_outcome=match t.io with
          | None -> Fs_compat.update_existing_private_file_durable_locked_result filename decide_rows
          | Some io -> Fs_compat.update_existing_private_file_durable_locked_with_io_for_testing
              ~io filename decide_rows in
        existing_outcome |> map_transaction_outcome
          ~value:(function None -> Error Unknown_operation | Some result -> result)
          ~error:(fun e -> Io_error (Fs_compat.private_jsonl_transaction_error_to_string e)) in
  let result=match outcome with
  | Fs_compat.Private_file_succeeded result -> Result.map (fun r -> {record=r;settlement_error=None}) result
  | Fs_compat.Private_file_succeeded_with_cleanup_failure {value;cleanup_failure} ->
      let detail=Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure in
      (match value with Ok r -> Ok {record=r;settlement_error=Some detail}
       | Error primary -> Error (Settlement_failed {primary;cleanup=detail}))
  | Fs_compat.Private_file_failed error -> Error error
  | Fs_compat.Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
      Error (Settlement_failed {primary=error;
        cleanup=Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure}) in
  (* Retire only after terminal journal commit; restart may safely retry retirement. *)
  Result.map (settle_marker t filename) result)
let admit t payload =
  let* ()=validate payload in
  transact t ~mode:Admit_operation ~caller:payload.caller ~operation_id:payload.operation_id (function
    | Some r when r.payload=payload -> Ok (None,r)
    | Some _ -> Error Conflict
    | None -> let* r=initial (event_payload payload) in Ok (Some (event_payload payload),r))
let find t ~caller ~operation_id =
  if String.trim caller="" then Error (Invalid_input "authenticated caller is required") else protect (fun () ->
  (* Share the writer's path mutex and descriptor lock without creating a file
     or its parent directory when this operation has never been admitted. *)
  let filename=path t caller operation_id in
  let outcome=match t.io with
    | None -> Fs_compat.read_private_jsonl_rows_locked_result filename
    | Some io -> Fs_compat.read_private_jsonl_rows_locked_with_io_for_testing ~io filename in
  let read = function
    | Fs_compat.Private_jsonl_rows.Rows_missing -> Ok None
    | Fs_compat.Private_jsonl_rows.Rows_present {rows;rows_end;end_offset} ->
        if rows_end<>end_offset then Error (Corrupt "incomplete delivery journal") else
        let* record=decode rows in
        match record with
        | Some r when r.payload.caller<>caller
            || not (Request_id.equal r.payload.operation_id operation_id) -> Error Conflict
        | record -> Ok record in
  let finish result cleanup = match result,cleanup with
    | Ok (Some record),settlement_error -> Ok (Some {record;settlement_error})
    | Ok None,None -> Ok None
    | Ok None,Some detail -> Error (Io_error detail)
    | Error primary,None -> Error primary
    | Error primary,Some cleanup -> Error (Settlement_failed {primary;cleanup}) in
  match outcome with
  | Fs_compat.Private_file_succeeded value -> finish (read value) None
  | Fs_compat.Private_file_succeeded_with_cleanup_failure {value;cleanup_failure} ->
      finish (read value) (Some (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
  | Fs_compat.Private_file_failed error ->
      Error (Io_error (Fs_compat.Private_jsonl_rows.error_to_string error))
  | Fs_compat.Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
      Error (Settlement_failed {
        primary=Io_error (Fs_compat.Private_jsonl_rows.error_to_string error);
        cleanup=Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure}))
let commit t ~caller ~operation_id ~seq =
  if seq<=0 then Error (Invalid_input "workspace sequence must be positive") else
  transact t ~mode:Update_operation ~caller ~operation_id (function
    | None -> Error Unknown_operation
    | Some r -> match r.workspace with
      | Committed previous when previous=seq -> Ok (None,r)
      | Committed _ -> Error Conflict
      | Uncommitted -> let event=`Assoc ["event",`String "committed";"seq",`Int seq] in
          let* next=transition r event in Ok (Some event,next))
let recipient_result t ~caller ~operation_id ~recipient state =
  transact t ~mode:Update_operation ~caller ~operation_id (function
    | None -> Error Unknown_operation
    | Some r ->
        let status,error=match state with Accepted -> "accepted",`Null
          | Pending None -> "pending",`Null | Pending (Some e) -> "pending",`String e in
        let event=`Assoc ["event",`String "recipient";"recipient",`String recipient;
          "state",`String status;"error",error] in
        let* next=transition r event |> Result.map_error (fun _ -> Conflict) in
        if next=r then Ok (None,r) else Ok (Some event,next))
let recover_after_scan t ~after_scan = protect (fun () ->
  let names = match Fs_compat.exact_path_kind (pending_dir t) with
    | Fs_compat.Exact_missing -> []
    | _ -> Fs_compat.read_dir (pending_dir t) |> List.sort String.compare in
  after_scan ();
  let recover_one recovery name =
    if not (Filename.check_suffix name ".jsonl") then Ok recovery else
    let digest=String.sub name 0 (String.length name-6) in
    if not (valid_digest digest) then Error (Corrupt "invalid pending journal filename") else
    let filename=Filename.concat t.root name in
    let outcome=existing_transaction t filename
      (fun bytes ->
        let decoded=decode bytes in
        (* Marker creation may precede a failed admission. Remove that empty
           marker while still holding the journal lock, so a concurrent admit
           must create its own marker after this cleanup. *)
        let decoded=match decoded with
          | Ok None -> Result.map (fun () -> None) (remove_marker t filename)
          | Ok (Some _) | Error _ -> decoded in
        None,decoded) in
    let present = function
      | None -> Error (Corrupt "pending journal is missing")
      | Some result -> result in
    let* record,settlement_error=match outcome with
      | Fs_compat.Private_file_succeeded result -> Result.map (fun r -> r,None) (present result)
      | Fs_compat.Private_file_succeeded_with_cleanup_failure {value;cleanup_failure} ->
          (match present value with
           | Ok r -> Ok (r,Some (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
           | Error primary -> Error (Settlement_failed {primary;
               cleanup=Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure}))
      | Fs_compat.Private_file_failed e -> Error (Io_error (Fs_compat.private_jsonl_transaction_error_to_string e))
      | Fs_compat.Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
          Error (Settlement_failed {primary=Io_error (Fs_compat.private_jsonl_transaction_error_to_string error);
            cleanup=Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure}) in
    match record with
    | None -> (match settlement_error with None -> Ok recovery | Some detail -> Error (Io_error detail))
    | Some record when filename<>path t record.payload.caller record.payload.operation_id ->
        let primary=Corrupt "journal identity disagrees with its path" in
        (match settlement_error with None -> Error primary
         | Some cleanup -> Error (Settlement_failed {primary;cleanup}))
    | Some record ->
        let receipt=settle_marker t filename {record;settlement_error} in
        let settlement_error=receipt.settlement_error in
        if complete record then (match settlement_error with
          | None -> Ok recovery
          | Some _ -> Ok {recovery with settled_with_cleanup=receipt::recovery.settled_with_cleanup})
        else Ok {recovery with pending=receipt::recovery.pending} in
  let recovery=List.fold_left (fun recovery name ->
    match protect (fun () -> recover_one recovery name) with
    | Ok next -> next
    | Error error -> {recovery with rejected=(name,error)::recovery.rejected})
    {pending=[];settled_with_cleanup=[];rejected=[]} names in
  Ok {pending=List.rev recovery.pending;
      settled_with_cleanup=List.rev recovery.settled_with_cleanup;
      rejected=List.rev recovery.rejected})

let recover t = recover_after_scan t ~after_scan:(fun () -> ())
module For_testing = struct
  let create ~root ~io = {root;io=Some io}
  let recover = recover_after_scan
end
