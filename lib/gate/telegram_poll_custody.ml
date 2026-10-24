module Api = Telegram_rest_client

type t = {client:Api.t;path:string;bot_user_id:int64}
type error =
  | Api of Api.error
  | Cursor_refused of string
  | Acceptance_refused of {update_id:int64;detail:string}
  | Storage_failed of string
let pp_error fmt = function
  | Api error -> Api.pp_error fmt error
  | Cursor_refused detail -> Format.fprintf fmt "telegram cursor refused: %s" detail
  | Acceptance_refused {update_id;detail} ->
    Format.fprintf fmt "telegram update %Ld acceptance refused: %s" update_id detail
  | Storage_failed detail -> Format.fprintf fmt "telegram cursor storage failed: %s" detail
let ( let* ) = Result.bind
let bot_user_id t = t.bot_user_id
let operation_id t (update : Api.update) =
  Printf.sprintf "telegram-bot-%Ld-update-%Ld" t.bot_user_id update.update_id
let int64_json n = `Intlit (Int64.to_string n)
let cursor_json t next_offset = Yojson.Safe.to_string (`Assoc [
  "schema_version",`Int 1; "bot_user_id",int64_json t.bot_user_id;
  "next_offset",(match next_offset with None -> `Null | Some n -> int64_json n)])
let integer64 = function
  | `Int n -> Some (Int64.of_int n)
  | `Intlit n -> Int64.of_string_opt n
  | _ -> None
let decode_cursor t body =
  let refused detail = Error (Cursor_refused detail) in
  let* json = Gate_rest_json.parse ~context:"telegram cursor" body
    |> Result.map_error (fun _ -> Cursor_refused "invalid or duplicate JSON") in
  match Gate_rest_json.to_yojson json with
  | `Assoc fields when List.length fields=3
      && List.for_all (fun (name,_) -> List.mem name ["schema_version";"bot_user_id";"next_offset"]) fields ->
    if List.assoc_opt "schema_version" fields <> Some (`Int 1) then refused "schema_version"
    else
      (match Option.bind (List.assoc_opt "bot_user_id" fields) integer64,
        List.assoc_opt "next_offset" fields with
       | Some bot,Some offset when bot=t.bot_user_id ->
         (match offset with
          | `Null -> Ok None
          | value -> (match integer64 value with
            | Some n when n >= 0L -> Ok (Some n)
            | Some _ | None -> refused "next_offset"))
       | Some _,_ -> refused "bot identity mismatch"
       | None,_ -> refused "bot_user_id")
  | _ -> refused "cursor fields"
let read_cursor t =
  match Fs_compat.load_file_opt t.path with
  | exception Sys_error detail -> Error (Storage_failed detail)
  | None -> Ok None
  | Some body ->
    let* offset = decode_cursor t body in
    (* After a prior rename-then-sync failure the visible file is not yet an
       acknowledgment authority. Sync it before any getUpdates can use it. *)
    let* () = Fs_compat.sync_file_and_parent_strict t.path |> Result.map_error (fun s -> Storage_failed s) in
    Ok offset
let open_cursor ?post ?clock ~client ~path () =
  let* bot = Api.get_me ?post ?clock client () |> Result.map_error (fun e -> Api e) in
  if not bot.is_bot then Error (Cursor_refused "getMe is not a bot")
  else
    let t={client;path;bot_user_id=bot.id} in
    let* _ = read_cursor t in Ok t

type ignored_reason = Unbound_chat | Bot_message | Unsupported_update | Empty_message
type disposition = Accepted of Gate_protocol.outbound_message | Intentionally_ignored of ignored_reason
type report = {next_offset:int64 option;accepted:int;ignored:int;already_committed:int}

let check_receipt ~operation_id (outbound : Gate_protocol.outbound_message) =
  match outbound.message_request with
  | None -> Error "missing durable operation receipt"
  | Some request ->
    if request.request_id <> operation_id || request.channel <> "telegram"
       || request.destination_type <> "keeper" || request.destination_id <> outbound.keeper_name
       || String.trim outbound.keeper_name = ""
    then Error "receipt does not identify its original update and Keeper"
    else match request.status with
      | Gate_protocol.Accepted | Queued | Running | Done | Failed | Cancelled -> Ok ()
      | Acceptance_uncertain | Lost -> Error "operation acceptance is unconfirmed"
let offset_contains offset (update : Api.update) =
  Option.fold ~none:false ~some:(fun n -> update.update_id < n) offset
let persist t next_offset =
  Fs_compat.save_file_atomic_strict t.path (cursor_json t (Some next_offset))
  |> Result.map_error (fun detail -> Storage_failed detail)
let step ?post ?clock t ~poll_timeout_sec ~accept () =
  let* offset = read_cursor t in
  let* updates = Api.get_updates ?post ?clock t.client ?offset ~poll_timeout_sec ()
    |> Result.map_error (fun error -> Api error) in
  let* () =
    match Fs_compat.mkdir_p (Filename.dirname t.path) with
    | () -> Ok ()
    | exception (Sys_error detail) -> Error (Storage_failed detail)
    | exception (Unix.Unix_error (code,fn,arg)) ->
      Error (Storage_failed (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))) in
  let observation = File_lock_eio.with_durable_lock_observed ~lock_path:(t.path ^ ".lock") (fun () ->
    let* next_offset = read_cursor t in
    let rec settle report = function
      | [] -> Ok report
      | (update : Api.update) :: rest when offset_contains report.next_offset update ->
        settle {report with already_committed=report.already_committed+1} rest
      | (update : Api.update) :: rest ->
        if update.update_id=Int64.max_int then Error (Cursor_refused "successor offset overflow")
        else
          let operation_id=operation_id t update in
          let* disposition = accept ~operation_id update
            |> Result.map_error (fun detail -> Acceptance_refused {update_id=update.update_id;detail}) in
          let* accepted,ignored = match disposition with
            | Intentionally_ignored (Unbound_chat | Bot_message | Unsupported_update | Empty_message) -> Ok (0,1)
            | Accepted outbound ->
              Result.map (fun () -> 1,0) (check_receipt ~operation_id outbound)
              |> Result.map_error (fun detail -> Acceptance_refused {update_id=update.update_id;detail}) in
          let next=Int64.succ update.update_id in
          let* () = persist t next in
          settle {report with next_offset=Some next;accepted=report.accepted+accepted;ignored=report.ignored+ignored} rest in
    settle {next_offset;accepted=0;ignored=0;already_committed=0} updates) in
  match observation with
  | File_lock_eio.Lock_not_acquired error -> Error (Storage_failed (File_lock_eio.durable_lock_error_to_string error))
  | Body_completed {value;release_error=None} -> value
  | Body_completed {value=_;release_error=Some error} ->
    Error (Storage_failed (File_lock_eio.durable_lock_error_to_string error))
