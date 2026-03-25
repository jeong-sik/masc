(** Tests for read_jsonl_tail_lines edge cases (issue #2922).
    Covers: empty files, fewer-than-limit lines, chunk-boundary splits,
    and both Eio-native and stdlib fallback paths. *)

open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "test_cp_jsonl_tail_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  try rm dir with _ -> ()

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc content)

(* --- stdlib fallback tests (no Eio fs set) --- *)

let test_empty_file () =
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let path = Filename.concat dir "empty.jsonl" in
    write_file path "";
    let result = Cp_io.read_jsonl_tail_lines path ~max_lines:10 in
    Alcotest.(check int) "empty file returns 0 lines" 0 (List.length result))

let test_nonexistent_file () =
  let result = Cp_io.read_jsonl_tail_lines "/tmp/no_such_file_ever.jsonl" ~max_lines:10 in
  Alcotest.(check int) "nonexistent returns 0 lines" 0 (List.length result)

let test_zero_max_lines () =
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let path = Filename.concat dir "data.jsonl" in
    write_file path "{\"a\":1}\n{\"b\":2}\n";
    let result = Cp_io.read_jsonl_tail_lines path ~max_lines:0 in
    Alcotest.(check int) "max_lines=0 returns 0" 0 (List.length result))

let test_fewer_than_limit () =
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let path = Filename.concat dir "few.jsonl" in
    write_file path "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n";
    let result = Cp_io.read_jsonl_tail_lines path ~max_lines:10 in
    Alcotest.(check int) "3 lines when asking for 10" 3 (List.length result);
    Alcotest.(check string) "first line" "{\"a\":1}" (List.nth result 0);
    Alcotest.(check string) "last line" "{\"c\":3}" (List.nth result 2))

let test_exact_limit () =
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let path = Filename.concat dir "exact.jsonl" in
    write_file path "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n";
    let result = Cp_io.read_jsonl_tail_lines path ~max_lines:3 in
    Alcotest.(check int) "exactly 3 lines" 3 (List.length result))

let test_more_than_limit () =
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let path = Filename.concat dir "many.jsonl" in
    let lines =
      List.init 20 (fun i -> Printf.sprintf "{\"i\":%d}" i)
    in
    write_file path (String.concat "\n" lines ^ "\n");
    let result = Cp_io.read_jsonl_tail_lines path ~max_lines:5 in
    Alcotest.(check int) "returns 5 lines" 5 (List.length result);
    Alcotest.(check string) "first returned is line 15" "{\"i\":15}" (List.nth result 0);
    Alcotest.(check string) "last returned is line 19" "{\"i\":19}" (List.nth result 4))

let test_chunk_boundary () =
  (* Create a file larger than 8192 bytes (chunk_size) to exercise
     multi-chunk backward reading and chunk-boundary line splits. *)
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let path = Filename.concat dir "big.jsonl" in
    (* Each line ~80 chars, 200 lines = ~16KB > 8192 chunk_size *)
    let lines =
      List.init 200 (fun i ->
        Printf.sprintf "{\"idx\":%d,\"pad\":\"%s\"}" i (String.make 60 'x'))
    in
    write_file path (String.concat "\n" lines ^ "\n");
    let result = Cp_io.read_jsonl_tail_lines path ~max_lines:10 in
    Alcotest.(check int) "returns 10 lines" 10 (List.length result);
    (* last line should be idx=199 *)
    let last = List.nth result 9 in
    let idx_ok =
      try
        match Yojson.Safe.from_string last with
        | `Assoc fields ->
          (match List.assoc_opt "idx" fields with
           | Some (`Int 199) -> true
           | _ -> false)
        | _ -> false
      with _ -> false
    in
    Alcotest.(check bool) "last line contains idx 199" true idx_ok)

let test_single_line_no_trailing_newline () =
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let path = Filename.concat dir "single.jsonl" in
    write_file path "{\"only\":true}";
    let result = Cp_io.read_jsonl_tail_lines path ~max_lines:5 in
    Alcotest.(check int) "single line without newline" 1 (List.length result);
    Alcotest.(check string) "content" "{\"only\":true}" (List.nth result 0))

let test_blank_lines_filtered () =
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let path = Filename.concat dir "blanks.jsonl" in
    write_file path "{\"a\":1}\n\n\n{\"b\":2}\n   \n{\"c\":3}\n";
    let result = Cp_io.read_jsonl_tail_lines path ~max_lines:10 in
    Alcotest.(check int) "blank lines filtered" 3 (List.length result))

(* --- Eio-native path tests --- *)

let test_eio_empty_file () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  Fs_compat.set_fs fs;
  Fun.protect ~finally:(fun () -> Fs_compat.clear_fs ()) (fun () ->
    let dir = temp_dir () in
    Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
      let path = Filename.concat dir "empty.jsonl" in
      write_file path "";
      let result = Cp_io.read_jsonl_tail_lines path ~max_lines:10 in
      Alcotest.(check int) "eio: empty file" 0 (List.length result)))

let test_eio_fewer_than_limit () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  Fs_compat.set_fs fs;
  Fun.protect ~finally:(fun () -> Fs_compat.clear_fs ()) (fun () ->
    let dir = temp_dir () in
    Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
      let path = Filename.concat dir "few.jsonl" in
      write_file path "{\"a\":1}\n{\"b\":2}\n";
      let result = Cp_io.read_jsonl_tail_lines path ~max_lines:10 in
      Alcotest.(check int) "eio: 2 lines" 2 (List.length result)))

let test_eio_chunk_boundary () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  Fs_compat.set_fs fs;
  Fun.protect ~finally:(fun () -> Fs_compat.clear_fs ()) (fun () ->
    let dir = temp_dir () in
    Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
      let path = Filename.concat dir "big.jsonl" in
      let lines =
        List.init 200 (fun i ->
          Printf.sprintf "{\"idx\":%d,\"pad\":\"%s\"}" i (String.make 60 'x'))
      in
      write_file path (String.concat "\n" lines ^ "\n");
      let result = Cp_io.read_jsonl_tail_lines path ~max_lines:10 in
      Alcotest.(check int) "eio: returns 10 lines" 10 (List.length result);
      let last = List.nth result 9 in
      let idx_ok =
        try
          match Yojson.Safe.from_string last with
          | `Assoc fields ->
            (match List.assoc_opt "idx" fields with
             | Some (`Int 199) -> true
             | _ -> false)
          | _ -> false
        with _ -> false
      in
      Alcotest.(check bool) "eio: last line is idx 199" true idx_ok))

let test_eio_more_than_limit () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  Fs_compat.set_fs fs;
  Fun.protect ~finally:(fun () -> Fs_compat.clear_fs ()) (fun () ->
    let dir = temp_dir () in
    Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
      let path = Filename.concat dir "many.jsonl" in
      let lines =
        List.init 20 (fun i -> Printf.sprintf "{\"i\":%d}" i)
      in
      write_file path (String.concat "\n" lines ^ "\n");
      let result = Cp_io.read_jsonl_tail_lines path ~max_lines:5 in
      Alcotest.(check int) "eio: returns 5" 5 (List.length result);
      Alcotest.(check string) "eio: first is 15" "{\"i\":15}" (List.nth result 0);
      Alcotest.(check string) "eio: last is 19" "{\"i\":19}" (List.nth result 4)))

let () =
  Alcotest.run "Cp_jsonl_tail"
    [
      ( "stdlib_fallback",
        [
          Alcotest.test_case "empty file" `Quick test_empty_file;
          Alcotest.test_case "nonexistent file" `Quick test_nonexistent_file;
          Alcotest.test_case "zero max_lines" `Quick test_zero_max_lines;
          Alcotest.test_case "fewer than limit" `Quick test_fewer_than_limit;
          Alcotest.test_case "exact limit" `Quick test_exact_limit;
          Alcotest.test_case "more than limit" `Quick test_more_than_limit;
          Alcotest.test_case "chunk boundary" `Quick test_chunk_boundary;
          Alcotest.test_case "single line no newline" `Quick test_single_line_no_trailing_newline;
          Alcotest.test_case "blank lines filtered" `Quick test_blank_lines_filtered;
        ] );
      ( "eio_native",
        [
          Alcotest.test_case "eio empty file" `Quick test_eio_empty_file;
          Alcotest.test_case "eio fewer than limit" `Quick test_eio_fewer_than_limit;
          Alcotest.test_case "eio chunk boundary" `Quick test_eio_chunk_boundary;
          Alcotest.test_case "eio more than limit" `Quick test_eio_more_than_limit;
        ] );
    ]
