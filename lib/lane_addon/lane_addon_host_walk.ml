type 'halt run = running_at_start:int -> (unit, 'halt) result

type 'halt step =
  | Skip
  | Halt of 'halt
  | Here of 'halt run
  | Beside of 'halt run

let walk ~max_in_flight ~propagates ~step requests =
  let max_in_flight = (max_in_flight : Lane_addon_config.exact_in_flight :> int) in
  Eio.Switch.run (fun sw ->
    (* These are touched only by fibers of this domain between effects, so
       they need no lock. *)
    let running = ref 0 and changed = Eio.Condition.create () in
    let halted = ref [] and raised = ref None and leaving = ref false in
    let stopped () =
      (match !halted with [] -> false | _ :: _ -> true) || Option.is_some !raised || !leaving in
    let settle index = function
      | Ok () -> ()
      | Error halt -> halted := (index, halt) :: !halted in
    (* One exception leaves the walk. A propagating one fails the switch,
       which cancels the running requests; it is let out only when it is the
       first exception of any kind, so the switch never holds two. Any other
       exception is kept, and the first of them is raised after the running
       requests end. *)
    let caught run =
      match run () with
      | () -> ()
      | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
      | exception exn when propagates exn ->
          if not (!leaving || Option.is_some !raised) then (leaving := true; raise exn)
      | exception exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          if not (!leaving || Option.is_some !raised) then raised := Some (exn, backtrace) in
    let start index request =
      match step request with
      | Skip -> ()
      | Halt halt -> settle index (Error halt)
      | Here run -> settle index (run ~running_at_start:!running)
      | Beside run ->
          let running_at_start = !running in
          incr running;
          Eio.Fiber.fork ~sw (fun () ->
            Fun.protect
              ~finally:(fun () -> decr running; Eio.Condition.broadcast changed)
              (fun () -> caught (fun () -> settle index (run ~running_at_start))));
          while !running >= max_in_flight do Eio.Condition.await_no_mutex changed done in
    let rec each index = function
      | [] -> ()
      | request :: rest ->
          if not (stopped ()) then (
            caught (fun () -> start index request);
            each (index + 1) rest) in
    each 0 requests;
    while !running > 0 do Eio.Condition.await_no_mutex changed done;
    match !raised with
    | Some (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
    | None ->
        (match List.sort (fun (left, _) (right, _) -> Int.compare left right) !halted with
         | [] -> None
         | (_, first) :: _ -> Some first))
