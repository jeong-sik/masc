open Masc

let h2_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

let with_pair f =
  Eio_main.run (fun env ->
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Switch.run (fun sw ->
        let server, client = Eio_unix.Net.socketpair_stream ~sw () in
        f sw server client)))

(* Forward the real socket, observing completion of its first read. This
   handshake prevents a writer from coalescing the rest into that first read. *)
module Observed_socket = struct
  type tag = [`Generic]
  type t =
    { flow : [`Generic] Eio.Net.stream_socket_ty Eio.Resource.t
    ; mutable first_read : int Eio.Promise.u option
    }

  let read_methods = []
  let single_read t dst =
    let count = Eio.Flow.single_read t.flow dst in
    (match t.first_read with
     | None -> ()
     | Some notify ->
       t.first_read <- None;
       Eio.Promise.resolve notify count);
    count

  let single_write t bufs = Eio.Flow.single_write t.flow bufs
  let copy t ~src = Eio.Flow.copy src t.flow
  let shutdown t command = Eio.Flow.shutdown t.flow command
  let close t = Eio.Flow.close t.flow
end

let observe_first_read flow =
  let first_read, notify = Eio.Promise.create () in
  let state = Observed_socket.
    { flow = (flow :> [`Generic] Eio.Net.stream_socket_ty Eio.Resource.t)
    ; first_read = Some notify
    }
  in
  Eio.Resource.T (state, Eio.Net.Pi.stream_socket (module Observed_socket)), first_read

let detect_exn flow =
  match Http_protocol_detect.detect flow with
  | Ok pair -> pair
  | Error message -> Alcotest.fail message

let check_protocol expected actual =
  Alcotest.(check string) "selected protocol" expected
    (Http_protocol_detect.protocol_to_string actual)

let read_string flow length =
  let buffer = Cstruct.create length in
  Eio.Flow.read_exact flow buffer;
  Cstruct.to_string buffer

let check_replay expected flow =
  (* Small reads exercise partially drained prefix state. The final read
     crosses to the underlying socket without losing or duplicating bytes. *)
  let first = read_string flow 1 in
  let rest = read_string flow (String.length expected - 1) in
  Alcotest.(check string) "all input replayed exactly once" expected (first ^ rest)

let test_delayed_protocol expected request =
  with_pair (fun sw server client ->
    let started, mark_started = Eio.Promise.create () in
    let selected = ref false in
    let detection = Eio.Fiber.fork_promise ~sw (fun () ->
      Eio.Promise.resolve mark_started ();
      let result = detect_exn server in
      selected := true;
      result)
    in
    Eio.Promise.await started;
    Eio.Fiber.yield ();
    Alcotest.(check bool) "caller runs while detector waits for first byte" false !selected;
    Eio.Flow.copy_string request client;
    let protocol, replay = Eio.Promise.await_exn detection in
    check_protocol expected protocol;
    check_replay request replay)

let test_fragmented_h2 () =
  (* Every split before the distinguishing prefix completes, including a
     single initial byte. The rest includes bytes beyond the detector buffer. *)
  for split = 1 to String.length "PRI * HTTP/2.0" - 1 do
    with_pair (fun sw server client ->
      let prefix = String.sub h2_preface 0 split in
      Eio.Flow.copy_string prefix client;
      let observed, first_read = observe_first_read server in
      let detection = Eio.Fiber.fork_promise ~sw (fun () -> detect_exn observed) in
      let consumed = Eio.Promise.await first_read in
      Alcotest.(check bool) "first read completed with only the initial H2 fragment" true
        (consumed > 0 && consumed <= split);
      let rest = String.sub h2_preface split (String.length h2_preface - split) in
      let settings = "\000\000\000\004\000\000\000\000\000" in
      Eio.Flow.copy_string (rest ^ settings) client;
      let protocol, replay = Eio.Promise.await_exn detection in
      check_protocol "HTTP/2" protocol;
      check_replay (h2_preface ^ settings) replay)
  done

let test_short_h1_and_socket_forwarding () =
  with_pair (fun _sw server client ->
    Eio.Flow.copy_string "G" client;
    let protocol, replay = detect_exn server in
    check_protocol "HTTP/1.1" protocol;
    Alcotest.(check bool) "wrapper cannot expose FD that bypasses prefix" true
      (Option.is_none (Eio_unix.Resource.fd_opt replay));
    Eio.Flow.copy_string "ET /health HTTP/1.1\r\n\r\n" client;
    check_replay "GET /health HTTP/1.1\r\n\r\n" replay;
    Eio.Flow.copy_string "response" replay;
    Eio.Flow.shutdown replay `Send;
    Alcotest.(check string) "writes reach peer" "response" (read_string client 8);
    let ended =
      try ignore (Eio.Flow.single_read client (Cstruct.create 1)); false
      with End_of_file -> true
    in
    Alcotest.(check bool) "send shutdown reaches peer" true ended;
    Eio.Flow.close replay;
    Eio.Flow.close replay)

let test_fragmented_h1_prefix () =
  with_pair (fun sw server client ->
    Eio.Flow.copy_string "P" client;
    let observed, first_read = observe_first_read server in
    let detection = Eio.Fiber.fork_promise ~sw (fun () -> detect_exn observed) in
    Alcotest.(check int) "first read completed with the initial H1 fragment" 1
      (Eio.Promise.await first_read);
    let rest = "OST /mcp HTTP/1.1\r\nHost: localhost\r\n\r\n" in
    Eio.Flow.copy_string rest client;
    let protocol, replay = Eio.Promise.await_exn detection in
    check_protocol "HTTP/1.1" protocol;
    check_replay ("P" ^ rest) replay)

let test_early_eof () =
  List.iter (fun prefix ->
    with_pair (fun _sw server client ->
      if prefix <> "" then Eio.Flow.copy_string prefix client;
      Eio.Flow.shutdown client `Send;
      match Http_protocol_detect.detect server with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "EOF must not select a protocol from absent/ambiguous bytes"))
    [ ""; "P"; "PRI * HTTP/2." ]

let test_cancel_waiting_detection () =
  List.iter (fun prefix ->
    with_pair (fun sw server client ->
      if prefix <> "" then Eio.Flow.copy_string prefix client;
      let observed, first_read = observe_first_read server in
      let context, mark_context = Eio.Promise.create () in
      let completed = ref false in
      let detection = Eio.Fiber.fork_promise ~sw (fun () ->
        try
          Eio.Cancel.sub (fun cc ->
            Eio.Promise.resolve mark_context cc;
            ignore (Http_protocol_detect.detect observed);
            completed := true);
          false
        with Eio.Cancel.Cancelled _ -> true)
      in
      let cc = Eio.Promise.await context in
      if prefix <> "" then ignore (Eio.Promise.await first_read)
      else Eio.Fiber.yield ();
      Eio.Cancel.cancel cc (Failure "cancel protocol detection");
      Alcotest.(check bool) "waiting read receives cancellation" true
        (Eio.Promise.await_exn detection);
      Alcotest.(check bool) "cancelled detector does not select a handler" false !completed))
    [ ""; "PRI " ]

let () =
  Alcotest.run "http_protocol_detect"
    [ "stream detection",
      [ Alcotest.test_case "delayed H2 preface" `Quick
          (fun () -> test_delayed_protocol "HTTP/2" h2_preface);
        Alcotest.test_case "delayed H1 request" `Quick
          (fun () -> test_delayed_protocol "HTTP/1.1" "GET / HTTP/1.1\r\n\r\n");
        Alcotest.test_case "fragmented H2 at every prefix split" `Quick test_fragmented_h2;
        Alcotest.test_case "short H1 and socket forwarding" `Quick test_short_h1_and_socket_forwarding;
        Alcotest.test_case "fragmented H1 shares initial P" `Quick test_fragmented_h1_prefix;
        Alcotest.test_case "EOF while undecided" `Quick test_early_eof;
        Alcotest.test_case "cancellation with no/partial bytes" `Quick test_cancel_waiting_detection ] ]
