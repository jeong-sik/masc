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
open Result.Syntax
let bot_user_id t = t.bot_user_id
type observation = Unobserved | Observed of {next_offset:int64 option;observed_at:float}
type cursor = {generation:int64;observation:observation}
let initial_cursor = {generation=0L;observation=Unobserved}
let next_offset cursor = match cursor.observation with Unobserved -> None | Observed o -> o.next_offset
let observed_at cursor = match cursor.observation with Unobserved -> None | Observed o -> Some o.observed_at
let operation_id t generation (update : Api.update) =
  Printf.sprintf "telegram-bot-%Ld-generation-%Ld-update-%Ld" t.bot_user_id generation update.update_id
let int64_json n = `Intlit (Int64.to_string n)
let cursor_json t (cursor : cursor) = Yojson.Safe.to_string (`Assoc [
  "schema_version",`Int 1; "bot_user_id",int64_json t.bot_user_id;
  "generation",int64_json cursor.generation;
  "observed_at",(match observed_at cursor with None -> `Null | Some n -> `Float n);
  "next_offset",(match next_offset cursor with None -> `Null | Some n -> int64_json n)])
let integer64 = function
  | `Int n -> Some (Int64.of_int n)
  | `Intlit n -> Int64.of_string_opt n
  | _ -> None
let finite value = Float.is_finite value && value >= 0.
let decode_cursor t body =
  let refused detail = Error (Cursor_refused detail) in
  let* json = Gate_rest_json.parse ~context:"telegram cursor" body
    |> Result.map_error (fun _ -> Cursor_refused "invalid or duplicate JSON") in
  match Gate_rest_json.to_yojson json with
  | `Assoc fields when List.length fields=5
      && List.for_all (fun (name,_) -> List.mem name
        ["schema_version";"bot_user_id";"generation";"next_offset";"observed_at"]) fields ->
    if List.assoc_opt "schema_version" fields <> Some (`Int 1) then refused "schema_version"
    else
      let* () = match Option.bind (List.assoc_opt "bot_user_id" fields) integer64 with
        | Some bot when bot=t.bot_user_id -> Ok ()
        | Some _ -> refused "bot identity mismatch" | None -> refused "bot_user_id" in
      let* generation = match Option.bind (List.assoc_opt "generation" fields) integer64 with
        | Some n when n>=0L -> Ok n | Some _ | None -> refused "generation" in
      let* next_offset = match List.assoc_opt "next_offset" fields with
        | Some `Null -> Ok None
        | Some value -> (match integer64 value with
          | Some n when n>=0L -> Ok (Some n) | Some _ | None -> refused "next_offset")
        | None -> refused "next_offset" in
      let* observed_at = match List.assoc_opt "observed_at" fields with
        | Some `Null -> Ok None
        | Some (`Float n) when finite n -> Ok (Some n)
        | Some (`Int n) when n>=0 -> Ok (Some (float_of_int n))
        | Some _ | None -> refused "observed_at" in
      (match next_offset,observed_at with
       | None,None -> Ok {generation;observation=Unobserved}
       | next_offset,Some observed_at -> Ok {generation;observation=Observed {next_offset;observed_at}}
       | Some _,None -> refused "offset observation pairing")
  | _ -> refused "cursor fields"
let read_cursor t =
  match Fs_compat.load_file_opt t.path with
  | exception Sys_error detail -> Error (Storage_failed detail)
  | None -> Ok initial_cursor
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
    let t={client;path=path ~bot_user_id:bot.id;bot_user_id=bot.id} in
    let* _ = read_cursor t in Ok t

type ignored_reason = Unbound_chat | Bot_message | Unsupported_update | Empty_message | Oversized_message
type disposition = Accepted of Gate_protocol.outbound_message | Intentionally_ignored of ignored_reason
type report = {generation:int64;next_offset:int64 option;accepted:int;ignored:int;already_committed:int}

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
let persist ~write_cursor t cursor =
  write_cursor t.path (cursor_json t cursor)
  |> Result.map_error (fun detail -> Storage_failed detail)
let with_cursor_lock t f =
  let* () =
    match Fs_compat.mkdir_p (Filename.dirname t.path) with
    | () -> Ok ()
    | exception (Sys_error detail) -> Error (Storage_failed detail)
    | exception (Unix.Unix_error (code,fn,arg)) ->
      Error (Storage_failed (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))) in
  match File_lock_eio.with_durable_lock_observed ~lock_path:(t.path ^ ".lock") f with
  | File_lock_eio.Lock_not_acquired error -> Error (Storage_failed (File_lock_eio.durable_lock_error_to_string error))
  | Body_completed {value;release_error=None} -> value
  | Body_completed {value=_;release_error=Some error} ->
    Error (Storage_failed (File_lock_eio.durable_lock_error_to_string error))

(* Bot API: updates live in the queue at most one day; after a week with no
   new update the next ID may be random. A page observed at poll start can
   therefore already be a day old. Retire its offset before that earliest
   possible reset. This is protocol acknowledgment validity, not work expiry. *)
let maximum_queue_age_sec = 24. *. 60. *. 60.
let id_reset_idle_sec = 7. *. maximum_queue_age_sec
let offset_validity_sec = id_reset_idle_sec -. maximum_queue_age_sec
let prepare_cursor ~write_cursor t ~now ~request_window_sec = with_cursor_lock t (fun () ->
  let* cursor=read_cursor t in
  (* Sample after admission: waiting for this lock cannot consume an earlier
     clock sample's acknowledgment validity. *)
  let request_started_at=now () in
  if not (finite request_started_at) then Error (Cursor_refused "invalid wall clock")
  else
    let* cursor = match observed_at cursor with
      | None -> Ok cursor
      | Some observed when request_started_at < observed -> Error (Cursor_refused "wall clock precedes cursor observation")
      | Some observed when request_started_at -. observed +. request_window_sec >= offset_validity_sec ->
        if cursor.generation=Int64.max_int then Error (Cursor_refused "generation overflow")
        else
          let fresh={generation=Int64.succ cursor.generation;observation=Unobserved} in
          let* ()=persist ~write_cursor t fresh in Ok fresh
      | Some _ -> Ok cursor in
    Ok (cursor,request_started_at))
let step_with_cursor_writer ~write_cursor ?post ~clock t ~now ~poll_timeout_sec ~accept () =
  let request_window_sec=float_of_int poll_timeout_sec +. Masc_http_client.default_request_timeout_sec in
  if poll_timeout_sec<0 then Error (Api(Api.Invalid_request "poll_timeout_sec"))
  else if not (finite request_window_sec) || request_window_sec>=maximum_queue_age_sec
  then Error (Cursor_refused "HTTP window cannot span the retained queue lifetime")
  else
    let* snapshot,poll_started_at=prepare_cursor ~write_cursor t ~now ~request_window_sec in
    let* updates = Api.get_updates ?post ~clock ~timeout_sec:request_window_sec t.client
      ?offset:(next_offset snapshot) ~poll_timeout_sec ()
      |> Result.map_error (fun error -> Api error) in
    with_cursor_lock t (fun () ->
      let* cursor=read_cursor t in
      let settled_at=now () in
      if not (finite settled_at) || settled_at<poll_started_at
      then Error (Cursor_refused "invalid settlement clock")
      else if settled_at -. poll_started_at >= request_window_sec
      then Error (Cursor_refused "poll response outlived its HTTP window; refetch")
      else if cursor.generation<>snapshot.generation then Error (Cursor_refused "poll generation changed; refetch")
      else
        (* Establish the observed generation BEFORE the first durable submit.
           A submit followed by a failed offset write must still leave enough
           history to retire that generation before Telegram can reuse an ID. *)
        let has_new = List.exists (fun update -> not(offset_contains (next_offset cursor) update)) updates in
        let observation_time=match observed_at cursor with
          | None -> poll_started_at | Some previous -> max previous poll_started_at in
        let* () = if has_new then
          persist ~write_cursor t {cursor with observation=Observed {next_offset=next_offset cursor;observed_at=observation_time}}
          else Ok () in
        let rec settle report = function
          | [] -> Ok report
          | (update : Api.update) :: rest when offset_contains report.next_offset update ->
            settle {report with already_committed=report.already_committed+1} rest
          | (update : Api.update) :: rest ->
            if update.update_id=Int64.max_int then Error (Cursor_refused "successor offset overflow")
            else
              let operation_id=operation_id t cursor.generation update in
              let* disposition = accept ~operation_id update
                |> Result.map_error (fun detail -> Acceptance_refused {update_id=update.update_id;detail}) in
              let* accepted,ignored = match disposition with
                | Intentionally_ignored (Unbound_chat | Bot_message | Unsupported_update | Empty_message | Oversized_message) -> Ok (0,1)
                | Accepted outbound ->
                  Result.map (fun () -> 1,0) (check_receipt ~operation_id outbound)
                  |> Result.map_error (fun detail -> Acceptance_refused {update_id=update.update_id;detail}) in
              let next=Int64.succ update.update_id in
              let* () = persist ~write_cursor t {generation=cursor.generation;
                observation=Observed {next_offset=Some next;observed_at=observation_time}} in
              settle {report with next_offset=Some next;accepted=report.accepted+accepted;ignored=report.ignored+ignored} rest in
        settle {generation=cursor.generation;next_offset=next_offset cursor;accepted=0;ignored=0;already_committed=0} updates)

let step ?post ~clock t ~now ~poll_timeout_sec ~accept () =
  step_with_cursor_writer ~write_cursor:Fs_compat.save_file_atomic_strict
    ?post ~clock t ~now ~poll_timeout_sec ~accept ()
module For_testing = struct
  let step_with_cursor_writer = step_with_cursor_writer
end
