type service_error =
  | Invalid_request of string
  | Store_error of Schedule_store.store_error
  | Creation_rejected of string

let ( let* ) = Result.bind

let service_error_to_string = function
  | Invalid_request msg -> "invalid request: " ^ msg
  | Store_error err -> Schedule_store.store_error_to_string err
  | Creation_rejected detail -> detail
;;

let map_store = function
  | Ok value -> Ok value
  | Error err -> Error (Store_error err)
;;

(* NDT-OK: service boundary clock; callers can pass explicit timestamps for replay/tests. *)
let now () = Unix.gettimeofday ()

let schedule_id = function
  | Some id -> id
  | None -> Random_id.prefixed ~prefix:"sched-" ~bytes:16
;;

let make_request
      ~schedule_id
      ?requested_at
      ?expires_at
      ~requested_by
      ~scheduled_by
      ~due_at
      ~payload
      ~source
      ?recurrence
      ()
  =
  (* NDT-OK: API boundary default; callers may provide requested_at explicitly. *)
  let requested_at = Option.value requested_at ~default:(now ()) in
  Schedule_domain.create_request ~schedule_id ~requested_by ~scheduled_by
    ~requested_at ~due_at ?expires_at ~payload ~source ?recurrence ()
  |> function
  | Ok request -> Ok request
  | Error msg -> Error (Invalid_request msg)
;;

let create
  config
  ?schedule_id:provided_schedule_id
  ?requested_at
  ?expires_at
  ~requested_by
  ~scheduled_by
  ~due_at
  ~payload
  ~source
  ?recurrence
  ()
  =
  let schedule_id = schedule_id provided_schedule_id in
  let* request =
    make_request ~schedule_id ?requested_at ?expires_at ~requested_by
      ~scheduled_by ~due_at ~payload ~source ?recurrence ()
  in
  Schedule_store.insert_request config request |> map_store
;;

let update
      config
      ~schedule_id
      ?requested_at
      ?expires_at
      ~requested_by
      ~scheduled_by
      ~due_at
      ~payload
      ~source
      ?recurrence
      ()
  =
  let* request =
    make_request ~schedule_id ?requested_at ?expires_at ~requested_by
      ~scheduled_by ~due_at ~payload ~source ?recurrence ()
  in
  Schedule_store.update_request config request |> map_store
;;

let cancel config ~schedule_id =
  Schedule_store.cancel_request config ~schedule_id |> map_store
;;

let prune config =
  match Schedule_store.prune_completed config with
  | Error err -> Error (Store_error err)
  | Ok (state, count) -> Ok (state, count)
;;
