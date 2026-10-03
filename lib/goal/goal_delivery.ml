let ( let* ) = Result.bind

type backend = {
  snapshot : config:Workspace_utils.config -> (string list, string) result;
  project : config:Workspace_utils.config ->
    delivery:Workspace_broadcast.broadcast_delivery -> recipient:string -> (unit, string) result;
}
let backend : backend option Atomic.t = Atomic.make None
let register_backend value = Atomic.set backend (Some value)
let protect work =
  try work () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
let store_result value = Result.map_error Goal_store.write_error_to_string value
let keep_first_error first next = match first with Ok () -> next | Error _ -> first

let deliver config host (notice : Goal_store.pending_notification) =
  let* current = match notice.delivery with
    | Goal_store.Pending_recipients _ -> Ok (Some notice)
    | Awaiting_recipients ->
        let* recipients = host.snapshot ~config in
        let recipients = List.filter (fun recipient -> recipient <> notice.sender) recipients in
        Goal_store.snapshot_notification_recipients config notice ~recipients |> store_result in
  match current with
  | None -> Ok ()
  | Some {delivery=Goal_store.Awaiting_recipients;_} -> Error "Goal recipients were not durably captured"
  | Some ({delivery=Goal_store.Pending_recipients recipients;_} as notice) ->
      let* delivery = Workspace_broadcast.broadcast_once
        ~fleet_delivery:Workspace_broadcast.Deferred_passive_fleet
        ~request_id:notice.notification_id config ~from_agent:notice.sender ~content:notice.content
        |> Result.map_error Workspace_broadcast.broadcast_error_to_string in
      let result = List.fold_left (fun result recipient ->
        let next = protect (fun () ->
          let* () = host.project ~config ~delivery ~recipient in
          Goal_store.acknowledge_notification_recipient config notice ~recipient |> store_result)
          |> Result.map_error (fun detail -> recipient ^ ": " ^ detail) in
        keep_first_error result next) (Ok ()) recipients in
      let* () = result in
      (* This checks the authoritative remaining set again. A failed transcript
         append or acknowledgement leaves the same identity for the next drain. *)
      Goal_store.acknowledge_notification config notice |> store_result

let flush config =
  let audit = protect (fun () -> Goal_store.flush_pending_events config)
    |> Result.map_error (fun detail -> "Goal audit: " ^ detail) in
  let notifications = protect (fun () ->
    let path = Filename.concat (Workspace_utils.masc_dir config) "goal-notification-delivery" in
    File_lock_eio.with_lock path (fun () ->
      let* notices = Goal_store.pending_notifications config |> store_result in
      match notices, Atomic.get backend with
      | [], _ -> Ok ()
      | _ :: _, None -> Error "Goal notification host boundary is unavailable"
      | _, Some host ->
          List.fold_left (fun result notice ->
            let next = protect (fun () -> deliver config host notice)
              |> Result.map_error (fun detail -> notice.Goal_store.notification_id ^ ": " ^ detail) in
            keep_first_error result next) (Ok ()) notices)) in
  keep_first_error audit notifications

module For_testing = struct
  let replace_backend value = Atomic.exchange backend value
end
