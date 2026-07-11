type outcome =
  | Completed
  | Cancelled_by_parent of exn
  | Failed of exn

type exit =
  { outcome : outcome
  ; cleanup_error : string option
  }

type state =
  | Not_started
  | Running
  | Exited

type t =
  { state : state Atomic.t
  ; exited_p : exit Eio.Promise.t
  ; exited_r : exit Eio.Promise.u
  }

type start_error =
  | Already_started
  | Already_exited
  | Fork_failed of exn

let start_error_to_string = function
  | Already_started -> "lane already started"
  | Already_exited -> "lane already exited"
  | Fork_failed exn -> Printf.sprintf "lane fork failed: %s" (Printexc.to_string exn)
;;

let create () =
  let exited_p, exited_r = Eio.Promise.create () in
  { state = Atomic.make Not_started; exited_p; exited_r }
;;

let exited t = t.exited_p
let peek_exit t = Eio.Promise.peek t.exited_p
let await_exit t = Eio.Promise.await t.exited_p

let rec claim_start t =
  if Atomic.compare_and_set t.state Not_started Running
  then Ok ()
  else
    match Atomic.get t.state with
    | Not_started -> claim_start t
    | Running -> Error Already_started
    | Exited -> Error Already_exited
;;

let cleanup_result cleanup outcome =
  Eio.Cancel.protect (fun () ->
    try
      match cleanup outcome with
      | Ok () -> None
      | Error detail -> Some detail
    with
    | exn -> Some (Printexc.to_string exn))
;;

let resolve_exit t outcome cleanup_error =
  Atomic.set t.state Exited;
  Eio.Promise.resolve t.exited_r { outcome; cleanup_error }
;;

let fork ~sw t ~run ~cleanup =
  match claim_start t with
  | Error _ as error -> error
  | Ok () ->
    (try
       Eio.Fiber.fork ~sw (fun () ->
         let outcome =
           try
             Eio.Switch.run (fun lane_sw -> run lane_sw);
             Completed
           with
           | Eio.Cancel.Cancelled cause -> Cancelled_by_parent cause
           | exn -> Failed exn
         in
         let cleanup_error = cleanup_result cleanup outcome in
         resolve_exit t outcome cleanup_error);
       Ok ()
     with
     | exn ->
       let outcome = Failed exn in
       let cleanup_error = cleanup_result cleanup outcome in
       resolve_exit t outcome cleanup_error;
       Error (Fork_failed exn))
;;

let reject_before_start t ~reason =
  match claim_start t with
  | Error _ as error -> error
  | Ok () ->
    resolve_exit t (Failed reason) None;
    Ok ()
;;
