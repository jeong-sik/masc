let gate () = Ok ()
let launch_side_effect () = ()

let guarded condition =
  match (match condition with true -> gate () | false -> gate ()) with
  | Error _ -> ()
  | Ok () -> launch_side_effect ()
;;

let side_effect_on_error condition =
  match (match condition with true -> gate () | false -> gate ()) with
  | Error _ -> launch_side_effect ()
  | Ok () -> launch_side_effect ()
;;

let gate_omitted_on_branch condition =
  match (if condition then gate () else Ok ()) with
  | Error _ -> ()
  | Ok () -> launch_side_effect ()
;;

let protected_cleanup_omitted () =
  Eio_guard.protect
    ~finally:(fun () -> ())
    (fun () -> run_cleanup_best_effort (fun () -> ()))
;;
