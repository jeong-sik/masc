type raised =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type cancelled =
  { reason : exn
  ; backtrace : Printexc.raw_backtrace
  }

type 'a callback_outcome =
  | Returned of 'a
  | Raised of raised
  | Cancelled of cancelled

type 'a t =
  { callback : 'a callback_outcome option
  ; scope_failure : raised option
  ; parent_cancellation : cancelled option
  }

let capture_callback f =
  match f () with
  | value -> Returned value
  | exception Eio.Cancel.Cancelled reason ->
    let backtrace = Printexc.get_raw_backtrace () in
    Cancelled { reason; backtrace }
  | exception exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Raised { exception_; backtrace }
;;

let capture_parent_cancellation () =
  try
    Eio.Fiber.check ();
    None
  with
  | Eio.Cancel.Cancelled reason ->
    let backtrace = Printexc.get_raw_backtrace () in
    Some { reason; backtrace }
;;

let run_resource_only f =
  let callback = ref None in
  let scope_failure =
    try
      Eio.Switch.run @@ fun sw ->
      callback := Some (capture_callback (fun () -> f sw));
      None
    with
    | exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      Some { exception_; backtrace }
  in
  let parent_cancellation =
    match !callback with
    | Some (Cancelled _) -> None
    | Some (Returned _ | Raised _) | None -> capture_parent_cancellation ()
  in
  { callback = !callback; scope_failure; parent_cancellation }
;;
