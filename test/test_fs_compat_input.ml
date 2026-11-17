open Alcotest
module Fs = Fs_compat
module Input = Fs.Input

let with_root f =
  let root = Filename.temp_dir "input-scope-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs.remove_tree root) (fun () -> f root)

let write path bytes = Out_channel.with_open_bin path (fun output -> output_string output bytes)

let assert_closed = function
  | None -> fail "input never opened"
  | Some fd ->
    (match Unix.fstat fd with
     | _ -> fail "input descriptor escaped settlement"
     | exception Unix.Unix_error (Unix.EBADF, _, _) -> ())

let assert_mutex path held =
  check bool "actual canonical path mutex availability" (not held)
    (Input.For_testing.path_mutex_available path)

let test_scope_and_bytes () = with_root (fun root ->
  let path = Filename.concat root "record" in
  let spelling = Filename.concat root "./record" in
  List.iter (fun bytes ->
    write path bytes;
    let fd = ref None and closed = ref 0 in
    let open_input received =
      check string "opener receives original spelling" spelling received;
      assert_mutex path true;
      let input = open_in_bin received in
      fd := Some (Unix.descr_of_in_channel input);
      input in
    let actual = Input.For_testing.with_open ~path:spelling ~open_input
      ~before_close:(fun input ->
        assert_mutex path true;
        check bool "same descriptor until close" true
          (!fd=Some (Unix.descr_of_in_channel input));
        incr closed)
      (fun input ->
        assert_mutex path false;
        let nested = Input.with_open ~path ~open_input:open_in_bin In_channel.input_all in
        check string "same-path nested read does not reenter a held mutex" bytes nested;
        In_channel.input_all input) in
    check string "raw bytes and final fragment retained" bytes actual;
    check int "one scope close" 1 !closed;
    assert_closed !fd;
    assert_mutex path false)
    [""; "first\r\n\nlast"; "\000binary\255\nunterminated"])

type rejection = Open_rejected | Body_rejected

let test_result_and_open_failure () = with_root (fun root ->
  let path = Filename.concat root "record" in
  write path "retained";
  let fd = ref None and used = ref false in
  let rejected path =
    assert_mutex path true;
    let input = open_in_bin path in
    fd := Some (Unix.descr_of_in_channel input);
    close_in_noerr input;
    Error Open_rejected in
  let actual = Input.with_open_result ~path ~open_input:rejected
      (fun _ -> used:=true; Ok ()) in
  check bool "opener result retained" true (actual=Error Open_rejected);
  check bool "rejected input never reaches body" false !used;
  assert_closed !fd;
  let actual = Input.with_open_result ~path
      ~open_input:(fun path -> let input=open_in_bin path in fd:=Some (Unix.descr_of_in_channel input); Ok input)
      (fun _ -> Error Body_rejected) in
  check bool "body result retained" true (actual=Error Body_rejected);
  assert_closed !fd;
  let failure = Sys_error "opener failed" in
  (match Input.with_open ~path ~open_input:(fun _ -> raise failure) ignore with
   | () -> fail "opener failure became success"
   | exception exn -> check bool "opener exception identity retained" true (exn==failure));
  assert_mutex path false)

let test_retained_descriptor_and_key () = with_root (fun root ->
  let first = Filename.concat root "first" and second = Filename.concat root "second" in
  Unix.mkdir first 0o700; Unix.mkdir second 0o700;
  let original = Filename.concat first "record" and other = Filename.concat second "record" in
  write original "old-one\nold-two\n"; write other "other\n";
  let alias = Filename.concat root "parent" in
  Unix.symlink first alias;
  let requested = Filename.concat alias "record" in
  let fd = ref None in
  let result = Input.For_testing.with_open ~path:requested
      ~open_input:(fun path -> let input=open_in_bin path in fd:=Some (Unix.descr_of_in_channel input); input)
      ~before_close:(fun _ ->
        assert_mutex original true;
        assert_mutex other false)
      (fun input ->
        let first_line = input_line input in
        let replacement = Filename.concat root "replacement" in
        write replacement "replacement\n"; Unix.rename replacement original;
        Unix.unlink alias; Unix.symlink second alias;
        first_line, In_channel.input_all input) in
  check (pair string string) "one retained channel survives pathname changes"
    ("old-one", "old-two\n") result;
  assert_closed !fd;
  assert_mutex original false)

exception Body_failure
exception Close_probe_failure

let test_primary_failure_and_backtrace () = with_root (fun root ->
  let path = Filename.concat root "record" in
  write path "retained";
  let fd = ref None and original_trace = ref None in
  let previous = Printexc.backtrace_status () in
  Printexc.record_backtrace true;
  Fun.protect ~finally:(fun () -> Printexc.record_backtrace previous) (fun () ->
    match Input.For_testing.with_open ~path
      ~open_input:(fun path -> let input=open_in_bin path in fd:=Some (Unix.descr_of_in_channel input); input)
      ~before_close:(fun _ -> assert_mutex path true; raise Close_probe_failure)
      (fun _ ->
        try raise Body_failure with Body_failure as exn ->
          let trace = Printexc.get_raw_backtrace () in
          original_trace := Some trace;
          Printexc.raise_with_backtrace exn trace) with
    | _ -> fail "body failure became a result"
    | exception Body_failure ->
      let observed = Printexc.get_raw_backtrace () in
      (match !original_trace with
       | None -> fail "body never raised"
       | Some original ->
         check bool "original raise frame recorded" true (Printexc.raw_backtrace_length original > 0);
         check bool "original raise frame retained after failed cleanup probe" true
           (Printexc.get_raw_backtrace_slot original 0=Printexc.get_raw_backtrace_slot observed 0)));
  assert_closed !fd;
  assert_mutex path false)

let with_fs filesystem f =
  let previous = Fs.get_fs_opt () in
  let set = function None -> Fs.clear_fs () | Some fs -> Fs.set_fs fs in
  set filesystem;
  Fun.protect ~finally:(fun () -> set previous) f

let test_eio_callback_and_dispatch () = Eio_main.run (fun env ->
  List.iter (fun filesystem -> with_fs filesystem (fun () -> with_root (fun root ->
    let path = Filename.concat root "record" in
    write path "first\nlast";
    let in_worker () =
      check bool "blocking stage is off the caller fiber" true (Fs.execution_context ()=Fs.Non_eio);
      assert_mutex path true in
    let result = Input.For_testing.with_open ~path
        ~open_input:(fun path -> in_worker (); open_in_bin path)
        ~before_close:(fun _ -> in_worker ())
        (fun input ->
          check bool "callback retains its Eio context" true (Fs.execution_context ()=Fs.Eio_fiber);
          assert_mutex path false;
          let first = input_line input in
          Eio.Fiber.yield ();
          let nested = Input.with_open ~path ~open_input:open_in_bin input_line in
          first, nested, In_channel.input_all input) in
    check (triple string string string) "one channel spans yielded callback and later read"
      ("first", "first", "last") result))) [None; Some (Eio.Stdenv.fs env)])

exception Cancel_read
type stop_stage = During_open | During_close | During_failed_body_close
type outcome = Returned | Cancelled | Body_raised

let test_cancellation_handoff_and_settlement () = Eio_main.run (fun _ ->
  List.iter (fun stage -> with_root (fun root ->
    let path = Filename.concat root "record" in
    write path "unchanged";
    let entered, resolve_entered = Eio.Promise.create () in
    let context, resolve_context = Eio.Promise.create () in
    let outcome, resolve_outcome = Eio.Promise.create () in
    let mutex = Stdlib.Mutex.create () and condition = Stdlib.Condition.create () in
    let released = ref false and descriptor = Atomic.make None in
    let used = Atomic.make 0 and closed = Atomic.make 0 in
    let release () = Stdlib.Mutex.protect mutex (fun () ->
      released:=true; Stdlib.Condition.broadcast condition) in
    let hold () =
      Eio.Promise.resolve resolve_entered ();
      Stdlib.Mutex.protect mutex (fun () ->
        while not !released do Stdlib.Condition.wait condition mutex done) in
    let open_input path =
      let input = open_in_bin path in
      Atomic.set descriptor (Some (Unix.descr_of_in_channel input));
      (match stage with During_open -> hold () | During_close | During_failed_body_close -> ());
      input in
    let before_close _ =
      assert_mutex path true;
      ignore (Atomic.fetch_and_add closed 1 : int);
      match stage with During_open -> () | During_close | During_failed_body_close -> hold () in
    Eio.Switch.run (fun sw ->
      Eio.Fiber.fork ~sw (fun () ->
        let result = try Eio.Cancel.sub (fun cancel ->
          Eio.Promise.resolve resolve_context cancel;
          Input.For_testing.with_open ~path ~open_input ~before_close (fun _ ->
            ignore (Atomic.fetch_and_add used 1 : int);
            match stage with During_failed_body_close -> raise Body_failure | During_open | During_close -> ());
          Returned)
          with Eio.Cancel.Cancelled _ -> Cancelled | Body_failure -> Body_raised in
        Eio.Promise.resolve resolve_outcome result);
      Fun.protect ~finally:release (fun () ->
        let cancel = Eio.Promise.await context in
        let did_enter = Eio.Fiber.first
          (fun () -> Eio.Promise.await entered; true)
          (fun () -> ignore (Eio.Promise.await outcome : outcome); false) in
        check bool "actual resource stage entered before cancellation" true did_enter;
        Eio.Cancel.cancel cancel Cancel_read;
        release ();
        match stage, Eio.Promise.await outcome with
        | (During_open | During_close), Cancelled | During_failed_body_close, Body_raised -> ()
        | (During_open | During_close | During_failed_body_close), (Returned | Cancelled | Body_raised) ->
          fail "cancellation/primary failure changed during ownership settlement"));
    check int "input closed exactly once" 1 (Atomic.get closed);
    check int "cancelled acquisition never enters callback"
      (match stage with During_open -> 0 | During_close | During_failed_body_close -> 1) (Atomic.get used);
    assert_closed (Atomic.get descriptor);
    assert_mutex path false)) [During_open; During_close; During_failed_body_close])

let () = run "Scoped input descriptor ownership" ["input", [
  test_case "raw bytes and unlocked nested callback" `Quick test_scope_and_bytes;
  test_case "admission and callback error results" `Quick test_result_and_open_failure;
  test_case "retained descriptor and captured canonical key" `Quick test_retained_descriptor_and_key;
  test_case "primary exception and backtrace survive cleanup failure" `Quick test_primary_failure_and_backtrace;
  test_case "Eio worker stages and yielding caller callback" `Quick test_eio_callback_and_dispatch;
  test_case "cancellation during open and close settles ownership" `Quick test_cancellation_handoff_and_settlement;
]]
