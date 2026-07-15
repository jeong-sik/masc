module Outbox = Fusion_completion_outbox

type route =
  { owner : string
  ; channel : Keeper_continuation_channel.t
  }
[@@deriving yojson]

type error =
  | Outbox_error of Outbox.error
  | Invalid_address of { operation_id : string; detail : string }
  | Operation_unavailable of string
  | Owner_mismatch of
      { operation_id : string
      ; expected_owner : string
      ; registered_owner : string
      }
  | Completion_state_conflict of
      { operation_id : string; registry_ok : bool; outbox_ok : bool }
  | Registry_completion_failed of Fusion_run_registry.completion_error
  | Lane_commit_failed of { operation_id : string; owner : string; detail : string }

type delivery_receipt = Delivered | Already_delivered

type drain_report = { delivered : int; failures : error list }

let error_to_string = function
  | Outbox_error error -> Outbox.error_to_string error
  | Invalid_address { operation_id; detail } ->
    Printf.sprintf "fusion address decode failed %s: %s" operation_id detail
  | Operation_unavailable operation_id ->
    Printf.sprintf "fusion canonical operation unavailable %s" operation_id
  | Owner_mismatch { operation_id; expected_owner; registered_owner } ->
    Printf.sprintf "fusion address owner mismatch %s: expected=%s registered=%s"
      operation_id expected_owner registered_owner
  | Completion_state_conflict { operation_id; registry_ok; outbox_ok } ->
    Printf.sprintf "fusion completion conflict %s: registry=%b outbox=%b"
      operation_id registry_ok outbox_ok
  | Registry_completion_failed error ->
    Fusion_run_registry.completion_error_to_string error
  | Lane_commit_failed { operation_id; owner; detail } ->
    Printf.sprintf "fusion lane commit failed %s/%s: %s" operation_id owner detail
;;

let address_of_route route =
  Outbox.Completion_address.of_opaque_string
    (Yojson.Safe.to_string (route_to_yojson route))
;;

let route_of_address ~operation_id address =
  let raw = Outbox.Completion_address.to_opaque_string address in
  try
    Yojson.Safe.from_string raw
    |> route_of_yojson
    |> Result.map_error (fun detail -> Invalid_address { operation_id; detail })
  with
  | exn -> Error (Invalid_address { operation_id; detail = Printexc.to_string exn })
;;

let registered_route operation_id =
  match Outbox.registered_address (Outbox.global ()) ~operation_id with
  | None -> Error (Outbox_error (Outbox.Unknown_address operation_id))
  | Some address -> route_of_address ~operation_id address
;;

let validate_known_owner ~operation_id route =
  match Fusion_run_registry.get (Fusion_run_registry.global ()) ~operation_id with
  | None -> Error (Operation_unavailable operation_id)
  | Some run ->
    let owner = Fusion_run_registry.keeper run in
    if String.equal owner route.owner
    then Ok ()
    else
      Error
        (Owner_mismatch
           { operation_id; expected_owner = owner; registered_owner = route.owner })
;;

let validate_registered_address operation_id =
  let ( let* ) = Result.bind in
  let* route = registered_route operation_id in
  validate_known_owner ~operation_id route
;;

let register ~operation_id ~owner ~channel =
  let route = { owner; channel } in
  match validate_known_owner ~operation_id route with
  | Error _ as error -> error
  | Ok () ->
    Outbox.register_address (Outbox.global ()) ~operation_id (address_of_route route)
    |> Result.map_error (fun error -> Outbox_error error)
;;

let completion ~ok ~content ~evidence_ref =
  let payload : Outbox.completion_payload = { content; evidence_ref } in
  if ok then Outbox.Succeeded payload else Outbox.Failed payload
;;

let ensure_registry_completion ~operation_id ~ok (payload : Outbox.completion_payload) =
  let persist ?failure ?failure_code () =
    Fusion_run_registry.mark_completed (Fusion_run_registry.global ())
      ~operation_id ?failure ?failure_code ~ok ()
    |> Result.map_error (fun error -> Registry_completion_failed error)
  in
  match Fusion_run_registry.get (Fusion_run_registry.global ()) ~operation_id with
  | None -> Ok ()
  | Some { status = (Running | Recovery_required _); _ } ->
    persist ?failure:(if ok then None else Some payload.content) ()
  | Some { status = Completed { ok = registry_ok; receipt = Durable; _ }; _ }
    when Bool.equal registry_ok ok -> Ok ()
  | Some
      { status = Completed { ok = registry_ok; receipt = Persistence_failed _; failure; failure_code }
      ; _
      }
    when Bool.equal registry_ok ok -> persist ?failure ?failure_code ()
  | Some { status = Completed { ok = registry_ok; _ }; _ } ->
    Error (Completion_state_conflict { operation_id; registry_ok; outbox_ok = ok })
;;

let queue_completion ~operation_id ~ok ~content ~evidence_ref =
  Outbox.complete (Outbox.global ()) ~operation_id
    (completion ~ok ~content ~evidence_ref)
  |> Result.map_error (fun error -> Outbox_error error)
;;

let deliver_item ~base_dir (item : Outbox.item) =
  let ( let* ) = Result.bind in
  let* route = registered_route item.operation_id in
  let* () =
    match
      Fusion_run_registry.get (Fusion_run_registry.global ())
        ~operation_id:item.operation_id
    with
    | None -> Ok ()
    | Some _ -> validate_known_owner ~operation_id:item.operation_id route
  in
  let ok, payload =
    match item.completion with
    | Outbox.Succeeded payload -> true, payload
    | Outbox.Failed payload -> false, payload
  in
  let* () = ensure_registry_completion ~operation_id:item.operation_id ~ok payload in
  let board_post_id = Option.value payload.evidence_ref ~default:"" in
  let fusion_completion =
    Keeper_event_queue.
      { run_id = item.operation_id
      ; ok
      ; resolved_answer = payload.content
      ; board_post_id
      ; channel = route.channel
      }
  in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = Keeper_event_queue.fusion_completion_post_id fusion_completion
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = Time_compat.now ()
    ; payload = Keeper_event_queue.Fusion_completed fusion_completion
    }
  in
  let* () =
    match
      try
        Keeper_registry_event_queue.enqueue_durable_result
          ~base_path:base_dir route.owner stimulus
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    with
    | Ok () -> Ok ()
    | Error detail ->
      Error
        (Lane_commit_failed
           { operation_id = item.operation_id; owner = route.owner; detail })
  in
  Outbox.acknowledge (Outbox.global ()) ~operation_id:item.operation_id
  |> Result.map
       (function
         | Outbox.Acknowledged -> Delivered
         | Outbox.Already_acknowledged -> Already_delivered)
  |> Result.map_error (fun error -> Outbox_error error)
;;

let pending_item operation_id =
  Outbox.pending (Outbox.global ())
  |> List.find_opt (fun (item : Outbox.item) -> String.equal item.operation_id operation_id)
;;

let complete_and_deliver ~base_dir ~operation_id ~ok ~content ~evidence_ref =
  match queue_completion ~operation_id ~ok ~content ~evidence_ref with
  | Error _ as error -> error
  | Ok Outbox.Already_delivered -> Ok Already_delivered
  | Ok (Outbox.Queued | Outbox.Already_pending) ->
    (match pending_item operation_id with
     | Some item -> deliver_item ~base_dir item
     | None -> Error (Outbox_error (Outbox.Unknown_completion operation_id)))
;;

let drain_all ~base_dir =
  Outbox.pending (Outbox.global ())
  |> List.fold_left
       (fun report (item : Outbox.item) ->
         match deliver_item ~base_dir item with
         | Ok _ ->
           Log.Misc.info "fusion completion delivered %s" item.operation_id;
           { report with delivered = report.delivered + 1 }
         | Error error ->
           Log.Misc.error "%s" (error_to_string error);
           { report with failures = error :: report.failures })
       { delivered = 0; failures = [] }
  |> fun report -> { report with failures = List.rev report.failures }
