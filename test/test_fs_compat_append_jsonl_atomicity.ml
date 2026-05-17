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

let () =
  Alcotest.run
    "fs_compat_append_jsonl_atomicity"
    [ "atomicity",
      [ test_case "16 threads × 100 multibyte records" `Quick test_concurrent_threads ]
    ]
