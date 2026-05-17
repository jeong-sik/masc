(** RFC-0107 tests: in-process atomic JSONL append.

    Three stress scenarios. Each constructs a fresh tmp file, drives a
    concurrent workload, then re-reads the file and asserts every line
    is parseable JSON. Any race-induced corruption (the 2026-05-17
    pre-fix symptoms: `}{` concat or utf-8 byte tear) surfaces as a
    [Yojson.Safe.from_string] failure. *)

open Alcotest

let counter = ref 0

let tmpdir prefix =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "%s_%d_%d_%.0f"
         prefix
         !counter
         (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  Unix.mkdir dir 0o755;
  dir

let read_lines path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let buf = Buffer.create 4096 in
      (try
         while true do
           Buffer.add_channel buf ic 4096
         done
       with End_of_file -> ());
      let content = Buffer.contents buf in
      String.split_on_char '\n' content
      |> List.filter (fun s -> s <> ""))

(* ── Scenario 1: 16 fibers × 1000 small records concurrent ────── *)

let test_concurrent_fibers () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let dir = tmpdir "jsonl_atomic_concurrent" in
  let path = Filename.concat dir "out.jsonl" in
  let writer =
    Jsonl_atomic.open_writer ~sw ~fs:(Eio.Stdenv.fs env) ~path
  in
  let n_fibers = 16 in
  let n_records_per_fiber = 1000 in
  let jobs =
    List.init n_fibers (fun fid () ->
      for seq = 0 to n_records_per_fiber - 1 do
        let json =
          `Assoc
            [
              ("fiber", `Int fid);
              ("seq", `Int seq);
              ("payload", `String "hello world");
            ]
        in
        match Jsonl_atomic.append writer json with
        | Ok () -> ()
        | Error (`Io msg) -> failwith ("append failed: " ^ msg)
      done)
  in
  Eio.Fiber.all jobs;
  Jsonl_atomic.close writer;
  let lines = read_lines path in
  check
    int
    "line count == fibers × records"
    (n_fibers * n_records_per_fiber)
    (List.length lines);
  (* Every line must parse, and we must see every (fiber, seq) exactly once. *)
  let seen = Hashtbl.create (n_fibers * n_records_per_fiber) in
  List.iter
    (fun line ->
      let json =
        try Yojson.Safe.from_string line
        with e ->
          failf
            "invalid JSON: %s\nline: %s"
            (Printexc.to_string e)
            line
      in
      let open Yojson.Safe.Util in
      let fid = json |> member "fiber" |> to_int in
      let seq = json |> member "seq" |> to_int in
      let key = (fid, seq) in
      if Hashtbl.mem seen key
      then failf "duplicate record: fiber=%d seq=%d" fid seq;
      Hashtbl.add seen key ())
    lines;
  check
    int
    "unique (fiber, seq) pairs"
    (n_fibers * n_records_per_fiber)
    (Hashtbl.length seen)

(* ── Scenario 2: PIPE_BUF-exceeding records (4 KB each) ──────── *)

let test_large_records () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let dir = tmpdir "jsonl_atomic_large" in
  let path = Filename.concat dir "out.jsonl" in
  let writer =
    Jsonl_atomic.open_writer ~sw ~fs:(Eio.Stdenv.fs env) ~path
  in
  (* Each record's serialized form is ~4 KB — well past macOS PIPE_BUF
     (512 B) and Linux PIPE_BUF (4 KB). *)
  let payload = String.make 4000 'A' in
  let n_fibers = 8 in
  let n_records_per_fiber = 125 in (* 8 × 125 = 1000 total *)
  let jobs =
    List.init n_fibers (fun fid () ->
      for seq = 0 to n_records_per_fiber - 1 do
        let json =
          `Assoc
            [
              ("fiber", `Int fid);
              ("seq", `Int seq);
              ("payload", `String payload);
            ]
        in
        match Jsonl_atomic.append writer json with
        | Ok () -> ()
        | Error (`Io msg) -> failwith ("append failed: " ^ msg)
      done)
  in
  Eio.Fiber.all jobs;
  Jsonl_atomic.close writer;
  let lines = read_lines path in
  check
    int
    "all large records present"
    (n_fibers * n_records_per_fiber)
    (List.length lines);
  List.iter
    (fun line ->
      let json =
        try Yojson.Safe.from_string line
        with e ->
          failf "invalid JSON (len=%d): %s" (String.length line)
            (Printexc.to_string e)
      in
      let open Yojson.Safe.Util in
      let p = json |> member "payload" |> to_string in
      check int "payload length preserved" 4000 (String.length p))
    lines

(* ── Scenario 3: multi-byte boundary stress (한글 padding) ───── *)

let test_multibyte_boundary () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let dir = tmpdir "jsonl_atomic_multibyte" in
  let path = Filename.concat dir "out.jsonl" in
  let writer =
    Jsonl_atomic.open_writer ~sw ~fs:(Eio.Stdenv.fs env) ~path
  in
  (* "가" is 3 bytes in UTF-8 (EA B0 80). Build records whose length
     sweeps a window across PIPE_BUF boundaries so multibyte sequences
     are routinely at the edges where a tearing writer would split
     them. *)
  let n_fibers = 16 in
  let n_records_per_fiber = 100 in (* 1600 total *)
  let make_payload seq =
    (* Mix of ASCII padding + Korean characters; length varies with seq
       to hit different byte offsets. *)
    let kor_count = 100 + (seq mod 300) in
    let kor = String.concat "" (List.init kor_count (fun _ -> "가")) in
    let ascii = String.make (seq mod 17) 'x' in
    ascii ^ kor
  in
  let jobs =
    List.init n_fibers (fun fid () ->
      for seq = 0 to n_records_per_fiber - 1 do
        let json =
          `Assoc
            [
              ("fiber", `Int fid);
              ("seq", `Int seq);
              ("k", `String (make_payload seq));
            ]
        in
        match Jsonl_atomic.append writer json with
        | Ok () -> ()
        | Error (`Io msg) -> failwith ("append failed: " ^ msg)
      done)
  in
  Eio.Fiber.all jobs;
  Jsonl_atomic.close writer;
  let lines = read_lines path in
  check
    int
    "all multibyte records present"
    (n_fibers * n_records_per_fiber)
    (List.length lines);
  (* Parse each line — utf-8 tear surfaces as Yojson exception. *)
  List.iter
    (fun line ->
      try ignore (Yojson.Safe.from_string line)
      with e ->
        failf
          "invalid JSON (len=%d): %s\nfirst bytes: %S"
          (String.length line)
          (Printexc.to_string e)
          (if String.length line > 80 then String.sub line 0 80
           else line))
    lines

(* ── Bonus: shared mutex across two writer handles ───────────── *)

let test_two_handles_share_mutex () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let dir = tmpdir "jsonl_atomic_two_handles" in
  let path = Filename.concat dir "out.jsonl" in
  let fs = Eio.Stdenv.fs env in
  let w1 = Jsonl_atomic.open_writer ~sw ~fs ~path in
  let w2 = Jsonl_atomic.open_writer ~sw ~fs ~path in
  let n = 500 in
  Eio.Fiber.both
    (fun () ->
      for i = 0 to n - 1 do
        match Jsonl_atomic.append w1 (`Assoc [("h", `Int 1); ("i", `Int i)]) with
        | Ok () -> ()
        | Error (`Io m) -> failwith m
      done)
    (fun () ->
      for i = 0 to n - 1 do
        match Jsonl_atomic.append w2 (`Assoc [("h", `Int 2); ("i", `Int i)]) with
        | Ok () -> ()
        | Error (`Io m) -> failwith m
      done);
  Jsonl_atomic.close w1;
  Jsonl_atomic.close w2;
  let lines = read_lines path in
  check int "all records from both handles" (2 * n) (List.length lines);
  List.iter
    (fun line ->
      try ignore (Yojson.Safe.from_string line)
      with e -> failf "invalid JSON: %s" (Printexc.to_string e))
    lines

let () =
  Alcotest.run
    "jsonl_atomic"
    [
      ( "atomicity",
        [
          test_case "16 fibers × 1000 records" `Quick test_concurrent_fibers;
          test_case "PIPE_BUF-exceeding records" `Quick test_large_records;
          test_case "multibyte boundary stress" `Quick test_multibyte_boundary;
          test_case "two handles share mutex" `Quick test_two_handles_share_mutex;
        ] );
    ]
