(** The walk of one host cycle listing (RFC
    host-cycle-runs-exact-requests-side-by-side 3.3 and 3.5). The requests
    here are the steps themselves, so each test states what every request
    does. *)
open Alcotest
module Walk = Masc.Lane_addon_host_walk
module Config = Masc.Lane_addon_config

exception Stop
exception Stop_because of string

let count n = match Config.exact_in_flight n with
  | Some count -> count
  | None -> fail "a count of 1 or more"

let never (_ : exn) = false
let on_stop = function Stop | Stop_because _ -> true | _ -> false
let in_eio f () = Eio_main.run (fun _env -> f ())

(* What the requests of one walk did, in the order it happened. *)
type trace = { mutable events : string list; mutable running : int; mutable most : int }

let trace () = { events = []; running = 0; most = 0 }
let note t event = t.events <- event :: t.events
let events t = List.rev t.events

(* A request that notes its start, and its end when [work] returns. *)
let body t name work ~running_at_start:(_ : int) =
  note t ("start " ^ name);
  t.running <- t.running + 1;
  t.most <- max t.most t.running;
  Fun.protect ~finally:(fun () -> t.running <- t.running - 1) (fun () ->
    let result = work () in
    note t ("end " ^ name);
    result)

let walk ?(propagates = never) n steps = Walk.walk ~max_in_flight:(count n) ~propagates ~step:Fun.id steps

let raised_by run = match run () with
  | (_ : string option) -> None
  | exception exn -> Some exn

let test_one_at_a_time_keeps_listing_order = in_eio (fun () ->
  let t = trace () in
  let yielding () = Eio.Fiber.yield (); Ok () in
  let halted = Walk.walk ~max_in_flight:Config.one_exact_at_a_time ~propagates:never ~step:Fun.id
      [ Walk.Beside (body t "a" yielding); Walk.Here (body t "b" yielding); Walk.Skip
      ; Walk.Beside (body t "c" yielding); Walk.Here (body t "d" yielding) ] in
  check (option string) "no halt" None halted;
  check (list string) "each request ends before the next starts"
    [ "start a"; "end a"; "start b"; "end b"; "start c"; "end c"; "start d"; "end d" ] (events t);
  check int "one request at a time" 1 t.most)

let test_no_more_than_the_count_run_together = in_eio (fun () ->
  let t = trace () in
  let seen = ref [] in
  let request name = Walk.Beside (fun ~running_at_start ->
    seen := running_at_start :: !seen;
    body t name (fun () -> Eio.Fiber.yield (); Eio.Fiber.yield (); Ok ()) ~running_at_start) in
  let halted = walk 2 (List.map request [ "a"; "b"; "c"; "d"; "e" ]) in
  check (option string) "no halt" None halted;
  check int "two run together and never three" 2 t.most;
  check int "every request ended" 5
    (List.length (List.filter (String.starts_with ~prefix:"end ") (events t)));
  check bool "each start saw fewer than the count beside it" true (List.for_all (fun n -> n < 2) !seen))

let test_a_halt_lets_the_running_requests_end = in_eio (fun () ->
  let t = trace () in
  let released, release = Eio.Promise.create () in
  let halted = ref None in
  Eio.Fiber.both
    (fun () -> halted := walk 3
      [ Walk.Beside (body t "slow" (fun () -> Eio.Promise.await released; Error "slow halted"))
      ; Walk.Beside (body t "quick" (fun () -> Error "quick halted"))
      ; Walk.Beside (body t "late" (fun () -> Ok ())) ])
    (fun () -> Eio.Promise.resolve release ());
  check (option string) "the first halt in listing order" (Some "slow halted") !halted;
  check (list string) "the running request ends and no later one starts"
    [ "start slow"; "start quick"; "end quick"; "end slow" ] (events t))

let test_a_listing_halt_starts_nothing_after_it = in_eio (fun () ->
  let t = trace () in
  let halted = walk 2
    [ Walk.Here (body t "a" (fun () -> Ok ())); Walk.Halt "listed again"
    ; Walk.Beside (body t "late" (fun () -> Ok ())) ] in
  check (option string) "the halt" (Some "listed again") halted;
  check (list string) "only the request before it ran" [ "start a"; "end a" ] (events t))

(* The broken request is at the walk itself or in its own fiber. Either way
   the request already running goes on to its end first. *)
let an_exception_waits_for_the_running_request place = in_eio (fun () ->
  let t = trace () in
  let released, release = Eio.Promise.create () in
  let raised = ref None in
  Eio.Fiber.both
    (fun () -> raised := raised_by (fun () -> walk 3
      [ Walk.Beside (body t "slow" (fun () -> Eio.Promise.await released; Ok ()))
      ; place (body t "broken" (fun () -> failwith "broken"))
      ; Walk.Beside (body t "late" (fun () -> Ok ())) ]))
    (fun () -> Eio.Promise.resolve release ());
  check bool "the exception leaves the walk as itself" true
    (match !raised with Some (Failure message) -> String.equal message "broken" | Some _ | None -> false);
  check (list string) "the running request ends and no later one starts"
    [ "start slow"; "start broken"; "end slow" ] (events t))

let test_a_fiber_exception_waits = an_exception_waits_for_the_running_request (fun run -> Walk.Beside run)
let test_a_walk_exception_waits = an_exception_waits_for_the_running_request (fun run -> Walk.Here run)

let test_a_propagating_exception_cancels_the_running_requests = in_eio (fun () ->
  let t = trace () in
  let cancelled = ref false in
  let raised = raised_by (fun () -> walk ~propagates:on_stop 2
    [ Walk.Beside (body t "running" (fun () ->
        try Eio.Fiber.await_cancel () with Eio.Cancel.Cancelled _ as exn -> cancelled := true; raise exn))
    ; Walk.Here (body t "stopping" (fun () -> raise Stop)) ]) in
  check bool "it leaves as itself" true (match raised with Some Stop -> true | Some _ | None -> false);
  check bool "the running request is cancelled" true !cancelled)

(* An instance that retires stops every running call, and each of them raises.
   The walk lets the first one out and nothing else. *)
let test_fibers_stopped_together_leave_as_one_exception = in_eio (fun () ->
  let t = trace () in
  let released, release = Eio.Promise.create () in
  let stopping name =
    Walk.Beside (body t name (fun () -> Eio.Promise.await released; raise (Stop_because name))) in
  let raised = ref None in
  Eio.Fiber.both
    (fun () -> raised := raised_by (fun () -> walk ~propagates:on_stop 2 [ stopping "a"; stopping "b" ]))
    (fun () -> Eio.Promise.resolve release ());
  check bool "the first exception, not a combination" true
    (match !raised with Some (Stop_because name) -> String.equal name "a" | Some _ | None -> false))

(* A request raised and the walk waits for the one still running. That one is
   then stopped. The kept exception is the one that leaves. *)
let test_a_kept_exception_outlives_a_later_stop = in_eio (fun () ->
  let t = trace () in
  let released, release = Eio.Promise.create () in
  let raised = ref None in
  Eio.Fiber.both
    (fun () -> raised := raised_by (fun () -> walk ~propagates:on_stop 3
      [ Walk.Beside (body t "stopping" (fun () -> Eio.Promise.await released; raise Stop))
      ; Walk.Beside (body t "broken" (fun () -> failwith "broken")) ]))
    (fun () -> Eio.Promise.resolve release ());
  check bool "the kept exception, not a combination" true
    (match !raised with Some (Failure message) -> String.equal message "broken" | Some _ | None -> false))

let () =
  run "lane_addon_host_walk"
    [ ( "walk"
      , [ test_case "one at a time keeps the listing order" `Quick test_one_at_a_time_keeps_listing_order
        ; test_case "no more than the count run together" `Quick test_no_more_than_the_count_run_together
        ; test_case "a halt lets the running requests end" `Quick test_a_halt_lets_the_running_requests_end
        ; test_case "a listing halt starts nothing after it" `Quick test_a_listing_halt_starts_nothing_after_it
        ; test_case "a fiber exception waits for the running request" `Quick test_a_fiber_exception_waits
        ; test_case "a walk exception waits for the running request" `Quick test_a_walk_exception_waits
        ; test_case "a propagating exception cancels the running requests" `Quick
            test_a_propagating_exception_cancels_the_running_requests
        ; test_case "fibers stopped together leave as one exception" `Quick
            test_fibers_stopped_together_leave_as_one_exception
        ; test_case "a kept exception outlives a later stop" `Quick test_a_kept_exception_outlives_a_later_stop ] ) ]
