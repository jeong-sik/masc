open Alcotest

module WP = With_process

(* ----- fd counting helper ---------------------------------------------- *)

(** Count open file descriptors for this process via lsof.  Uses WP itself
    so that leaks in the helper surface as baseline drift, not silent. *)
let count_open_fds () =
  let pid = Unix.getpid () in
  let cmd = Printf.sprintf "lsof -p %d 2>/dev/null | wc -l" pid in
  let lines, _ = WP.with_process_in cmd WP.drain_lines in
  match lines with
  | [] -> 0
  | line :: _ -> (try int_of_string (String.trim line) with _ -> 0)

(* ----- tests ----------------------------------------------------------- *)

let test_happy_path () =
  let lines, status =
    WP.with_process_args_in "/bin/echo" [| "/bin/echo"; "hello" |]
      WP.drain_lines
  in
  check (list string) "stdout lines" [ "hello" ] lines;
  (match status with
   | Unix.WEXITED 0 -> ()
   | _ -> fail "expected WEXITED 0")

let test_sys_error_closes_pipe () =
  let before = count_open_fds () in
  let raised = ref false in
  (try
     let _ : unit * Unix.process_status =
       WP.with_process_args_in "/bin/echo" [| "/bin/echo"; "fail" |]
         (fun _ic -> raise (Sys_error "synthetic"))
     in
     ()
   with Sys_error msg when msg = "synthetic" -> raised := true);
  check bool "exception propagated" true !raised;
  (* give kernel a moment to reclaim *)
  let after = count_open_fds () in
  check bool
    (Printf.sprintf "fd delta bounded before=%d after=%d" before after)
    true (after <= before + 1)

let test_cancelled_closes_pipe_and_reraises () =
  let before = count_open_fds () in
  let raised = ref false in
  (try
     let _ : unit * Unix.process_status =
       WP.with_process_args_in "/bin/echo" [| "/bin/echo"; "c" |]
         (fun _ic -> raise (Eio.Cancel.Cancelled (Failure "synthetic")))
     in
     ()
   with Eio.Cancel.Cancelled _ -> raised := true);
  check bool "cancelled re-raised" true !raised;
  let after = count_open_fds () in
  check bool
    (Printf.sprintf "fd delta bounded before=%d after=%d" before after)
    true (after <= before + 1)

let test_stress_no_leak () =
  let before = count_open_fds () in
  for _ = 1 to 100 do
    try
      let _ : unit * Unix.process_status =
        WP.with_process_args_in "/bin/echo" [| "/bin/echo"; "x" |]
          (fun _ic -> raise (Sys_error "drop"))
      in
      ()
    with Sys_error _ -> ()
  done;
  let after = count_open_fds () in
  (* tolerate +2 for lsof transient fds, but NOT +100 *)
  check bool
    (Printf.sprintf "100-iter fd delta bounded before=%d after=%d"
       before after)
    true (after <= before + 2)

let test_drain_to_buffer () =
  let buf, _ =
    WP.with_process_args_in "/bin/echo" [| "/bin/echo"; "ab" |]
      WP.drain_to_buffer
  in
  check string "buffer contents" "ab\n" (Buffer.contents buf)

let test_process_guard_wraps_helpers () =
  let depth = Atomic.make 0 in
  let high_water = Atomic.make 0 in
  let update_high () =
    let cur = Atomic.get depth in
    let rec bump () =
      let h = Atomic.get high_water in
      if cur > h then
        if Atomic.compare_and_set high_water h cur then () else bump ()
    in
    bump ()
  in
  WP.set_process_guard
    { WP.run =
        (fun f ->
          Atomic.incr depth;
          update_high ();
          Fun.protect ~finally:(fun () -> Atomic.decr depth) f)
    };
  Fun.protect ~finally:WP.reset_process_guard_for_testing (fun () ->
      let lines, _ =
        WP.with_process_args_in "/bin/echo" [| "/bin/echo"; "guard" |]
          WP.drain_lines
      in
      check (list string) "guarded stdout" [ "guard" ] lines;
      let lines, _ = WP.with_process_in "printf guard2" WP.drain_lines in
      check (list string) "guarded shell stdout" [ "guard2" ] lines;
      check int "guard high-water" 1 (Atomic.get high_water);
      check int "guard released" 0 (Atomic.get depth))

let () =
  run "with_process"
    [
      ( "happy_path",
        [
          test_case "echo returns stdout" `Quick test_happy_path;
          test_case "drain_to_buffer fills buffer" `Quick
            test_drain_to_buffer;
        ] );
      ( "guard",
        [ test_case "process guard wraps helpers" `Quick
            test_process_guard_wraps_helpers ] );
      ( "error_path",
        [
          test_case "Sys_error in callback closes pipe" `Quick
            test_sys_error_closes_pipe;
          test_case "Cancelled in callback closes and re-raises" `Quick
            test_cancelled_closes_pipe_and_reraises;
        ] );
      ( "stress",
        [
          test_case "100 iterations with exceptions — fd bounded" `Quick
            test_stress_no_leak;
        ] );
    ]
