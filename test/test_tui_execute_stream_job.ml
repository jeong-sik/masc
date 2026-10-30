(* The connection loop of the Terminal tab's Execute output stream, with the
   socket replaced by a script. What it has to do: show the rows a connection
   delivered, say when a connection ended and why, wait before the next one,
   post rows that arrive together together, and end quietly when it is stopped.

   The frames the script delivers are made by the server's own module, so the
   reader inside the job reads what the route really writes. *)

module EO = Dashboard_execute_output
module S = Masc_tui_execute_stream
module Job = Masc_tui_execute_stream_job

let keeper = "alpha"

(* Long enough to tell a pause from none, short enough for a test to wait. *)
let reconnect_s = 0.05
let post_interval_s = 0.01

(* A wait that has not ended by now has failed. *)
let patience_s = 5.0
let poll_s = 0.002

type event =
  | Viewed of string list
  | Ended of string

let event =
  Alcotest.testable
    (fun ppf -> function
       | Viewed texts -> Format.fprintf ppf "Viewed [%s]" (String.concat "; " texts)
       | Ended reason -> Format.fprintf ppf "Ended %S" reason)
    ( = )
;;

let texts_of_view = function
  | S.Awaiting_first_frame -> [ "(awaiting)" ]
  | S.Nothing_observed -> [ "(nothing)" ]
  | S.Observed reading -> List.map (fun (line : S.line) -> line.text) reading.lines
;;

let recorded events =
  ( (fun view -> events := Viewed (texts_of_view view) :: !events)
  , fun reason -> events := Ended reason :: !events )
;;

let with_env test () = Eio_main.run (fun env -> test env)

(* What the route writes first on a connection to a Keeper that has run one
   command with these rows of output. *)
let head ~rows =
  EO.reset_for_testing ();
  EO.record_stream_start ~keeper_name:keeper ~stream_id:1 ~task_id:None ~command:"run";
  List.iter
    (fun text ->
       EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout (text ^ "\n"))
    rows;
  match EO.subscribe ~keeper_name:keeper with
  | None -> Alcotest.fail "the server gave no subscriber"
  | Some subscriber ->
    Fun.protect
      ~finally:(fun () -> EO.unsubscribe subscriber)
      (fun () -> "retry: 1500\n\n" ^ EO.sse_frame (EO.initial_event_json subscriber))
;;

(* The first frame, then [rows] more rows as events. *)
let burst env ~rows =
  EO.reset_for_testing ();
  EO.record_stream_start ~keeper_name:keeper ~stream_id:1 ~task_id:None ~command:"run";
  match EO.subscribe ~keeper_name:keeper with
  | None -> Alcotest.fail "the server gave no subscriber"
  | Some subscriber ->
    Fun.protect
      ~finally:(fun () -> EO.unsubscribe subscriber)
      (fun () ->
         let first = "retry: 1500\n\n" ^ EO.sse_frame (EO.initial_event_json subscriber) in
         EO.append_stream_chunk
           ~keeper_name:keeper
           ~stream_id:1
           ~stream:`Stdout
           (String.concat "" (List.init rows (fun index -> Printf.sprintf "row %d\n" index)));
         let clock = Eio.Stdenv.clock env in
         let frames =
           List.init rows (fun _ ->
             Eio.Time.with_timeout_exn clock 1.0 (fun () ->
               EO.sse_frame (EO.stream_event_json (EO.take_event subscriber))))
         in
         first, frames)
;;

let wait_until env what predicate =
  let clock = Eio.Stdenv.clock env in
  match
    Eio.Time.with_timeout clock patience_s (fun () ->
      while not (predicate ()) do
        Eio.Time.sleep clock poll_s
      done;
      Ok ())
  with
  | Ok () -> ()
  | Error `Timeout -> Alcotest.failf "gave up waiting for %s" what
;;

(* Runs the job beside [body] with [observe] for the socket, and ends it when
   [body] returns. *)
let with_job env ~observe body =
  let clock = Eio.Stdenv.clock env in
  let events = ref [] in
  let on_view, on_ended = recorded events in
  let reader = S.create ~keeper ~capacity:500 in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Job.run ~clock ~reconnect_s ~post_interval_s ~reader ~observe ~on_view ~on_ended;
      `Stop_daemon);
    body (fun () -> List.rev !events))
;;

let test_rows_are_shown_and_the_end_is_reported_before_the_next_connection env =
  let clock = Eio.Stdenv.clock env in
  let head_one = head ~rows:[ "one" ] in
  let head_two = head ~rows:[ "two" ] in
  let started = ref [] in
  let observe ~on_chunk =
    started := Eio.Time.now clock :: !started;
    match List.length !started with
    | 1 ->
      on_chunk head_one;
      Error "the network went away"
    | 2 ->
      on_chunk head_two;
      Ok ()
    | _ -> Eio.Fiber.await_cancel ()
  in
  with_job env ~observe (fun events ->
    wait_until env "the third connection" (fun () -> List.length !started >= 3);
    Alcotest.(check (list event))
      "the rows, then why the connection ended, for each connection"
      [ Viewed [ "run"; "one" ]
      ; Ended "the network went away"
      ; Viewed [ "run"; "two" ]
      ; Ended "the server closed the Execute output stream"
      ]
      (events ());
    match List.rev !started with
    | [ first; second; third ] ->
      Alcotest.(check bool) "a pause before the second connection" true (second -. first >= reconnect_s);
      Alcotest.(check bool) "and before the third" true (third -. second >= reconnect_s)
    | other -> Alcotest.failf "expected three connections, got %d" (List.length other))
;;

let test_a_frame_the_reader_refuses_ends_the_connection env =
  let started = ref 0 in
  let observe ~on_chunk =
    incr started;
    if !started = 1
    then
      (* A real connection stops delivering once [on_chunk] raises; the script
         would wait here forever if the job let the frame pass. *)
      on_chunk "data: {not json\n\n";
    Eio.Fiber.await_cancel ()
  in
  with_job env ~observe (fun events ->
    wait_until env "the refusal to be reported" (fun () ->
      List.exists
        (function
          | Ended _ -> true
          | Viewed _ -> false)
        (events ()));
    (match
       List.filter_map
         (function
           | Ended reason -> Some reason
           | Viewed _ -> None)
         (events ())
     with
     | [ reason ] ->
       Alcotest.(check bool)
         "it says the frame could not be read"
         true
         (String_util.contains_substring reason "cannot read")
     | other -> Alcotest.failf "expected one end, got %d" (List.length other));
    wait_until env "the next connection" (fun () -> !started >= 2))
;;

let test_rows_that_arrive_together_are_posted_together env =
  let first, frames = burst env ~rows:200 in
  let observe ~on_chunk =
    on_chunk first;
    List.iter on_chunk frames;
    Eio.Fiber.await_cancel ()
  in
  with_job env ~observe (fun events ->
    let views () =
      List.filter_map
        (function
          | Viewed texts -> Some texts
          | Ended _ -> None)
        (events ())
    in
    wait_until env "the rows to be posted" (fun () -> views () <> []);
    (* The job posts when the reader changed, so a quiet connection posts
       nothing more. *)
    Eio.Time.sleep (Eio.Stdenv.clock env) (10. *. post_interval_s);
    match views () with
    | [ texts ] -> Alcotest.(check int) "the command row and every row after it" 201 (List.length texts)
    | other -> Alcotest.failf "expected one post for the burst, got %d" (List.length other))
;;

let test_stopping_the_job_cancels_the_connection_and_reports_nothing env =
  let clock = Eio.Stdenv.clock env in
  let head_one = head ~rows:[ "one" ] in
  let started = ref 0 in
  let cancelled = ref false in
  let observe ~on_chunk =
    incr started;
    on_chunk head_one;
    Fun.protect ~finally:(fun () -> cancelled := true) (fun () -> Eio.Fiber.await_cancel ())
  in
  let events = ref [] in
  let on_view, on_ended = recorded events in
  let reader = S.create ~keeper ~capacity:500 in
  let stopped, stop = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Fiber.first
        (fun () ->
           Job.run ~clock ~reconnect_s ~post_interval_s ~reader ~observe ~on_view ~on_ended)
        (fun () -> Eio.Promise.await stopped));
    wait_until env "the rows to be posted" (fun () -> !events <> []);
    Eio.Promise.resolve stop ();
    wait_until env "the connection to be cancelled" (fun () -> !cancelled);
    (* Long enough for a job that was still running to end the connection and
       open another. *)
    Eio.Time.sleep clock (3. *. reconnect_s);
    Alcotest.(check (list event))
      "the rows were posted and nothing was said about the end"
      [ Viewed [ "run"; "one" ] ]
      (List.rev !events);
    Alcotest.(check int) "no connection was opened after the stop" 1 !started)
;;

let () =
  let case name test = Alcotest.test_case name `Quick (with_env test) in
  Alcotest.run
    "Tui_execute_stream_job"
    [ ( "connections"
      , [ case
            "rows are shown and the end is reported before the next connection"
            test_rows_are_shown_and_the_end_is_reported_before_the_next_connection
        ; case
            "a frame the reader refuses ends the connection"
            test_a_frame_the_reader_refuses_ends_the_connection
        ] )
    ; ( "posting"
      , [ case
            "rows that arrive together are posted together"
            test_rows_that_arrive_together_are_posted_together
        ] )
    ; ( "stopping"
      , [ case
            "stopping the job cancels the connection and reports nothing"
            test_stopping_the_job_cancels_the_connection_and_reports_nothing
        ] )
    ]
;;
