(** RFC-0108 root fix: stress for [Fs_compat.append_jsonl] under
    cross-domain contention. Same shape as
    [test_trajectory_atomicity] / [test_system_log_atomicity], but
    targets the root helper used by 30+ callers so a single proof
    covers all of them. *)

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
  if not (Sys.file_exists path) then []
  else
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

let test_concurrent_threads () =
  let dir = tmpdir "fs_compat_append_jsonl" in
  let path = Filename.concat dir "out.jsonl" in
  let n_threads = 16 in
  let n_records_per_thread = 100 in
  let threads =
    List.init n_threads (fun tid ->
      Thread.create
        (fun () ->
          for seq = 0 to n_records_per_thread - 1 do
            (* Multibyte payload of varying length so utf-8 sequences
               land at different byte offsets — the surface where the
               shared-channel buffer corrupted records pre-fix. *)
            let kor_count = 100 + (seq mod 300) in
            let kor =
              String.concat "" (List.init kor_count (fun _ -> "가"))
            in
            let json =
              `Assoc
                [
                  ("tid", `Int tid);
                  ("seq", `Int seq);
                  ("k", `String kor);
                ]
            in
            Fs_compat.append_jsonl path json
          done)
        ())
  in
  List.iter Thread.join threads;
  let lines = read_lines path in
  check
    int
    "line count == threads × records"
    (n_threads * n_records_per_thread)
    (List.length lines);
  let seen = Hashtbl.create (n_threads * n_records_per_thread) in
  List.iter
    (fun line ->
      let json =
        try Yojson.Safe.from_string line
        with e ->
          failf
            "invalid JSON (len=%d): %s\nfirst bytes: %S"
            (String.length line)
            (Printexc.to_string e)
            (if String.length line > 60 then String.sub line 0 60
             else line)
      in
      let open Yojson.Safe.Util in
      let tid = json |> member "tid" |> to_int in
      let seq = json |> member "seq" |> to_int in
      let key = (tid, seq) in
      if Hashtbl.mem seen key
      then failf "duplicate record: tid=%d seq=%d" tid seq;
      Hashtbl.add seen key ())
    lines;
  check
    int
    "unique (tid, seq) pairs"
    (n_threads * n_records_per_thread)
    (Hashtbl.length seen)

let test_mixed_append_file_and_jsonl_share_mutex () =
  let dir = tmpdir "fs_compat_mixed_append" in
  let path = Filename.concat dir "out.jsonl" in
  let n_threads = 12 in
  let n_records_per_thread = 80 in
  let threads =
    List.init n_threads (fun tid ->
      Thread.create
        (fun () ->
          for seq = 0 to n_records_per_thread - 1 do
            let payload =
              String.concat "" (List.init (140 + (seq mod 37)) (fun _ -> "가"))
            in
            let json =
              `Assoc
                [
                  ("tid", `Int tid);
                  ("seq", `Int seq);
                  ( "writer",
                    `String (if tid mod 2 = 0 then "append_jsonl" else "append_file") );
                  ("payload", `String payload);
                ]
            in
            if tid mod 2 = 0 then Fs_compat.append_jsonl path json
            else Fs_compat.append_file path (Yojson.Safe.to_string json ^ "\n")
          done)
        ())
  in
  List.iter Thread.join threads;
  let lines = read_lines path in
  check int "line count == mixed writers × records"
    (n_threads * n_records_per_thread)
    (List.length lines);
  let seen = Hashtbl.create (n_threads * n_records_per_thread) in
  List.iter
    (fun line ->
      let json =
        try Yojson.Safe.from_string line
        with e ->
          failf "invalid mixed JSONL row (len=%d): %s\nfirst bytes: %S"
            (String.length line)
            (Printexc.to_string e)
            (if String.length line > 60 then String.sub line 0 60 else line)
      in
      let open Yojson.Safe.Util in
      let tid = json |> member "tid" |> to_int in
      let seq = json |> member "seq" |> to_int in
      let writer = json |> member "writer" |> to_string in
      let expected_writer =
        if tid mod 2 = 0 then "append_jsonl" else "append_file"
      in
      check string "writer tag matches tid parity" expected_writer writer;
      let key = (tid, seq) in
      if Hashtbl.mem seen key
      then failf "duplicate mixed record: tid=%d seq=%d" tid seq;
      Hashtbl.add seen key ())
    lines;
  check int "unique mixed (tid, seq) pairs"
    (n_threads * n_records_per_thread)
    (Hashtbl.length seen)

(* A reader on this very scheduler can release a blocked FIFO open/write.
   No elapsed-time threshold: success requires the original bytes to arrive. *)
let test_eio_fifo_append append =
  let dir = tmpdir "fs_compat_eio_fifo" in
  let path = Filename.concat dir "out.jsonl" in
  Unix.mkfifo path 0o600;
  let rows = [ `String "한글 첫 기록"; `Assoc [ "second", `Bool true ] ] in
  let expected =
    String.concat "" (List.map (fun row -> Yojson.Safe.to_string row ^ "\n") rows)
  in
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.reset_fd_cache_for_testing ();
      Unix.unlink path;
      Unix.rmdir dir)
    (fun () ->
      Eio_main.run (fun _env ->
        Eio.Fiber.both
          (fun () -> append path rows)
          (fun () ->
            let received =
              Eio_unix.run_in_systhread (fun () ->
                let ic = open_in_bin path in
                Fun.protect ~finally:(fun () -> close_in_noerr ic)
                  (fun () -> really_input_string ic (String.length expected)))
            in
            check string "all original records received" expected received)))

let test_eio_mixed_writers () =
  let dir = tmpdir "fs_compat_eio_mixed" in
  let path = Filename.concat dir "out.jsonl" in
  let row writer index =
    `Assoc [ "writer", `String writer; "index", `Int index;
             "payload", `String (String.make 8192 'x' ^ "한글") ]
  in
  let expected =
    [ row "single" 1; row "batch" 1; row "batch" 2; row "string" 1 ]
  in
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.reset_fd_cache_for_testing ();
      Unix.unlink path;
      Unix.rmdir dir)
    (fun () ->
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Fun.protect ~finally:Fs_compat.clear_fs (fun () ->
          Eio.Fiber.all
            [ (fun () -> Fs_compat.append_jsonl path (row "single" 1));
              (fun () -> Fs_compat.append_jsonl_batch path
                  [ row "batch" 1; row "batch" 2 ]);
              (fun () -> Fs_compat.append_file path
                  (Yojson.Safe.to_string (row "string" 1) ^ "\n")) ]));
      let actual = read_lines path |> List.map Yojson.Safe.from_string in
      let canonical rows = List.map Yojson.Safe.to_string rows |> List.sort String.compare in
      check (list string) "complete records persisted exactly once"
        (canonical expected) (canonical actual);
      let batch_rows =
        actual |> List.filter (fun value ->
          Yojson.Safe.Util.(value |> member "writer" |> to_string) = "batch")
      in
      check (list int) "batch order retained" [ 1; 2 ]
        (List.map (fun value -> Yojson.Safe.Util.(value |> member "index" |> to_int)) batch_rows))

let test_eio_errors_and_empty_batch () =
  let dir = tmpdir "fs_compat_eio_error" in
  Fun.protect ~finally:(fun () -> Unix.rmdir dir) (fun () ->
    Eio_main.run (fun _env ->
      let refused append =
        match append () with
        | () -> fail "append to directory should fail"
        | exception Sys_error _ -> ()
        | exception Unix.Unix_error _ -> ()
      in
      refused (fun () -> Fs_compat.append_jsonl dir (`String "single"));
      refused (fun () -> Fs_compat.append_jsonl_batch dir [ `String "batch" ]);
      let absent = Filename.concat dir "absent/out.jsonl" in
      Fs_compat.append_jsonl_batch absent [];
      check bool "empty batch does not create parent" false
        (Sys.file_exists (Filename.dirname absent))))

let test_cancelled_before_append append =
  let dir = tmpdir "fs_compat_cancel_before" in
  let path = Filename.concat dir "absent/out.jsonl" in
  Fun.protect ~finally:(fun () -> Unix.rmdir dir) (fun () ->
    Eio_main.run (fun _env ->
      let cancelled =
        try
          Eio.Cancel.sub (fun context ->
            Eio.Cancel.cancel context Exit;
            append path [ `String "must not be written" ]);
          false
        with Eio.Cancel.Cancelled _ -> true
      in
      check bool "dispatch refused cancellation" true cancelled;
      check bool "no directory was created" false
        (Sys.file_exists (Filename.dirname path))))

let test_cancelled_during_append append =
  let dir = tmpdir "fs_compat_cancel_entered" in
  let path = Filename.concat dir "out.jsonl" in
  Unix.mkfifo path 0o600;
  (* Exceeds the FIFO buffer so opening the reader confirms that the writer
     entered, while withholding reads keeps that original job outstanding. *)
  let row = `String (String.make (4 * 1024 * 1024) 'x') in
  let expected = Yojson.Safe.to_string row ^ "\n" in
  let acknowledged = ref false in
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.reset_fd_cache_for_testing ();
      Unix.unlink path;
      Unix.rmdir dir)
    (fun () ->
      Eio_main.run (fun _env ->
        Eio.Switch.run (fun sw ->
          let context, publish_context = Eio.Promise.create () in
          let settled, publish_settled = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
            let result =
              try
                Eio.Cancel.sub (fun cancel ->
                  Eio.Promise.resolve publish_context cancel;
                  append path [ row ];
                  acknowledged := true);
                Ok ()
              with
              | Eio.Cancel.Cancelled _ -> Ok ()
              | exn -> Error exn
            in
            Eio.Promise.resolve publish_settled result);
          let cancel = Eio.Promise.await context in
          let ic = Eio_unix.run_in_systhread (fun () -> open_in_bin path) in
          Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
            Eio.Cancel.cancel cancel Exit;
            let actual = Eio_unix.run_in_systhread (fun () ->
              really_input_string ic (String.length expected)) in
            (match Eio.Promise.await settled with
             | Ok () -> ()
             | Error exn -> raise exn);
            check bool "commit acknowledgement after joined write" true !acknowledged;
            check bool "original record completed" true (String.equal expected actual);
            Unix.set_nonblock (Unix.descr_of_in_channel ic);
            (match input_char ic with
             | _ -> fail "unexpected bytes after the completed record"
             | exception End_of_file -> ()
             | exception Sys_blocked_io -> ())))))

let () =
  Alcotest.run
    "fs_compat_append_jsonl_atomicity"
    [ "atomicity",
      [
        test_case "16 threads × 100 multibyte records" `Quick
          test_concurrent_threads;
        test_case "append_file and append_jsonl share path mutex" `Quick
          test_mixed_append_file_and_jsonl_share_mutex;
        test_case "Eio single appends yield to their FIFO reader" `Quick
          (fun () -> test_eio_fifo_append (fun path rows ->
            List.iter (Fs_compat.append_jsonl path) rows));
        test_case "Eio batch append yields to its FIFO reader" `Quick
          (fun () -> test_eio_fifo_append Fs_compat.append_jsonl_batch);
        test_case "Eio mixed writers retain complete records" `Quick
          test_eio_mixed_writers;
        test_case "Eio writer errors and empty batches retain their result" `Quick
          test_eio_errors_and_empty_batch;
        test_case "single append cancelled before dispatch" `Quick
          (fun () -> test_cancelled_before_append (fun path rows ->
            List.iter (Fs_compat.append_jsonl path) rows));
        test_case "batch append cancelled before dispatch" `Quick
          (fun () -> test_cancelled_before_append Fs_compat.append_jsonl_batch);
        test_case "single append cancellation waits for commit acknowledgement" `Quick
          (fun () -> test_cancelled_during_append (fun path rows ->
            List.iter (Fs_compat.append_jsonl path) rows));
        test_case "batch append cancellation waits for commit acknowledgement" `Quick
          (fun () -> test_cancelled_during_append Fs_compat.append_jsonl_batch);
      ]
    ]
