type 'halt run = running_at_start:int -> (unit, 'halt) result

type 'halt step =
  | Skip
  | Halt of 'halt
  | Here of 'halt run
  | Beside of 'halt run

type ('request, 'halt) listing =
  | Done
  | Page of 'request * 'request list * (unit -> (('request, 'halt) listing, 'halt) result)

let walk ~max_in_flight ~propagates ~step listing =
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
          if !leaving || Option.is_some !raised then
            Log.Misc.warn "Lane Add-on host walk dropped an exception raised after the one that leaves: %s"
              (Printexc.to_string exn)
          else raised := Some (exn, backtrace) in
    let start index request =
      match step request with
      | Skip -> ()
      | Halt halt -> settle index (Error halt)
      | Here run -> settle index (run ~running_at_start:!running)
      | Beside run ->
          let running_at_start = !running in
          (* The fiber counts itself: a switch that is already off runs no
             fiber, and then nothing would take the count back. *)
          Eio.Fiber.fork ~sw (fun () ->
            incr running;
            Fun.protect
              ~finally:(fun () -> decr running; Eio.Condition.broadcast changed)
              (fun () -> caught (fun () -> settle index (run ~running_at_start))));
          while !running >= max_in_flight do Eio.Condition.await_no_mutex changed done in
    let rec each index = function
      | [] -> index
      | request :: rest ->
          if stopped () then index
          else (
            caught (fun () -> start index request);
            each (index + 1) rest) in
    (* [caught] wraps the reading alone. Around the pages that follow it would
       take the propagating exception a request of those pages lets out. *)
    let read next =
      let answer = ref None in
      caught (fun () -> answer := Some (next ()));
      !answer in
    (* The requests of the pages before keep running while the next page is
       read, so the count of running requests does not fall at a page end. *)
    let rec pages index = function
      | Done -> ()
      | Page (first, rest, next) ->
          let index = each index (first :: rest) in
          if not (stopped ()) then (
            match read next with
            | Some (Ok listing) -> pages index listing
            | Some (Error halt) -> settle index (Error halt)
            | None -> ()) in
    pages 0 listing;
    while !running > 0 do Eio.Condition.await_no_mutex changed done;
    match !raised with
    | Some (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
    | None ->
        (match List.sort (fun (left, _) (right, _) -> Int.compare left right) !halted with
         | [] -> None
         | (_, first) :: _ -> Some first))
