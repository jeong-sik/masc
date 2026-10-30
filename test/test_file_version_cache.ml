open Alcotest

let with_file f =
  let dir = Filename.temp_dir "file_version_cache" "" in
  let path = Filename.concat dir "document" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with Sys_error _ -> ());
      try Sys.rmdir dir with Sys_error _ -> ())
    (fun () -> f path)
;;

let write path contents =
  Out_channel.with_open_bin path (fun channel -> output_string channel contents)
;;

let append path contents =
  Out_channel.with_open_gen
    [ Open_wronly; Open_append; Open_binary ]
    0o600
    path
    (fun channel -> output_string channel contents)
;;

let read path = In_channel.with_open_bin path In_channel.input_all

(* A decode that counts its runs and returns the file's text. *)
let counting_decode path =
  let runs = ref 0 in
  let decode () =
    incr runs;
    Ok (read path)
  in
  decode, runs
;;

let load cache path ~decode =
  match File_version_cache.load cache path ~decode with
  | Ok value -> value
  | Error () -> fail "the decode failed"
;;

let test_an_unchanged_file_is_decoded_once () =
  with_file
  @@ fun path ->
  write path "one";
  let cache = File_version_cache.create () in
  let decode, runs = counting_decode path in
  let first = load cache path ~decode in
  let second = load cache path ~decode in
  check string "the kept value" "one" second;
  check bool "is the value the first read decoded" true (first == second);
  check int "decoded once" 1 !runs
;;

let test_an_append_is_decoded_again () =
  with_file
  @@ fun path ->
  write path "one";
  let cache = File_version_cache.create () in
  let decode, runs = counting_decode path in
  ignore (load cache path ~decode : string);
  append path " two";
  check string "the appended file" "one two" (load cache path ~decode);
  check int "decoded again" 2 !runs
;;

(* A replacement written beside the file and renamed over it has the same
   size but a new inode. *)
let test_a_replaced_file_of_the_same_size_is_decoded_again () =
  with_file
  @@ fun path ->
  write path "one";
  let cache = File_version_cache.create () in
  let decode, runs = counting_decode path in
  ignore (load cache path ~decode : string);
  let replacement = path ^ ".next" in
  write replacement "two";
  Unix.rename replacement path;
  check string "the replacement" "two" (load cache path ~decode);
  check int "decoded again" 2 !runs
;;

let test_a_forgotten_file_is_decoded_again () =
  with_file
  @@ fun path ->
  write path "one";
  let cache = File_version_cache.create () in
  let decode, runs = counting_decode path in
  ignore (load cache path ~decode : string);
  File_version_cache.forget cache path;
  ignore (load cache path ~decode : string);
  check int "decoded again" 2 !runs
;;

(* A write that lands while the decode runs leaves the file at a version the
   decoded value does not describe, so the value is returned but not kept. *)
let test_a_write_during_the_decode_is_not_kept () =
  with_file
  @@ fun path ->
  write path "one";
  let cache = File_version_cache.create () in
  let runs = ref 0 in
  let decode () =
    incr runs;
    let seen = read path in
    if !runs = 1 then append path " two";
    Ok seen
  in
  check string "the first read returns what it decoded" "one" (load cache path ~decode);
  check string "the next read decodes the written file" "one two" (load cache path ~decode);
  check int "decoded twice" 2 !runs
;;

(* A write that keeps the file's version is seen only through the writer's
   [forget]. Here it lands while the first decode runs: the value that decode
   read may be the one from before the write, so it is returned but not kept,
   and the next read decodes again. Keeping resumes after that. *)
let test_a_forget_during_the_decode_is_not_undone () =
  with_file
  @@ fun path ->
  write path "one";
  let cache = File_version_cache.create () in
  let runs = ref 0 in
  let decode () =
    incr runs;
    let seen = read path in
    if !runs = 1 then File_version_cache.forget cache path;
    Ok seen
  in
  ignore (load cache path ~decode : string);
  ignore (load cache path ~decode : string);
  check int "the read after the forget decodes again" 2 !runs;
  ignore (load cache path ~decode : string);
  check int "and keeps its value" 2 !runs
;;

(* A whole-second modification time that [Unix.utimes] puts back exactly. *)
let pinned_mtime = 1_700_000_000.0
let pin_mtime path mtime = Unix.utimes path mtime mtime

(* The same forget with a real write behind it: the file is rewritten in
   place at the same size and its modification time put back, so only the
   forget shows the write. The read after it returns what the file holds. *)
let test_a_write_seen_only_through_forget_is_read () =
  with_file
  @@ fun path ->
  write path "one";
  pin_mtime path pinned_mtime;
  let cache = File_version_cache.create () in
  let runs = ref 0 in
  let decode () =
    incr runs;
    let seen = read path in
    if !runs = 1
    then begin
      write path "two";
      pin_mtime path pinned_mtime;
      File_version_cache.forget cache path
    end;
    Ok seen
  in
  check string "the first read returns what it decoded" "one" (load cache path ~decode);
  check string "the next read returns the rewritten file" "two" (load cache path ~decode)
;;

(* A writer that never forgets rewrites the file under a new modification
   time. The next decode reads that, but a forget of another file lands while
   it runs, so its value is not kept. The file then goes back to its first
   version with other bytes. The entry kept for that first version must be
   gone by then, or it answers for the new bytes. *)
let test_a_declined_keep_drops_an_entry_for_another_version () =
  with_file
  @@ fun path ->
  write path "one";
  pin_mtime path pinned_mtime;
  let cache = File_version_cache.create () in
  let runs = ref 0 in
  let decode () =
    incr runs;
    let seen = read path in
    if !runs = 2 then File_version_cache.forget cache (path ^ ".other");
    Ok seen
  in
  check string "the first version is kept" "one" (load cache path ~decode);
  write path "two";
  pin_mtime path (pinned_mtime +. 1.0);
  check string "the rewrite is read" "two" (load cache path ~decode);
  write path "six";
  pin_mtime path pinned_mtime;
  check string "the first version with other bytes is read, not answered from the entry"
    "six" (load cache path ~decode);
  check int "decoded three times" 3 !runs
;;

let test_an_error_is_not_kept () =
  with_file
  @@ fun path ->
  write path "one";
  let cache = File_version_cache.create () in
  let runs = ref 0 in
  let decode () =
    incr runs;
    Error ()
  in
  let failed () =
    match File_version_cache.load cache path ~decode with
    | Error () -> true
    | Ok (_ : string) -> false
  in
  check bool "the first read fails" true (failed ());
  check bool "the second read fails" true (failed ());
  check int "decoded every time" 2 !runs
;;

let test_a_missing_file_is_decoded_every_time () =
  with_file
  @@ fun path ->
  let cache = File_version_cache.create () in
  let runs = ref 0 in
  let decode () =
    incr runs;
    Ok "absent"
  in
  ignore (load cache path ~decode : string);
  ignore (load cache path ~decode : string);
  check int "decoded every time" 2 !runs
;;

let () =
  run
    "file version cache"
    [ ( "load"
      , [ test_case "an unchanged file is decoded once" `Quick
            test_an_unchanged_file_is_decoded_once
        ; test_case "an append is decoded again" `Quick test_an_append_is_decoded_again
        ; test_case "a replaced file of the same size is decoded again" `Quick
            test_a_replaced_file_of_the_same_size_is_decoded_again
        ; test_case "a forgotten file is decoded again" `Quick
            test_a_forgotten_file_is_decoded_again
        ; test_case "a write during the decode is not kept" `Quick
            test_a_write_during_the_decode_is_not_kept
        ; test_case "a write seen only through forget is read" `Quick
            test_a_write_seen_only_through_forget_is_read
        ; test_case "a declined keep drops an entry for another version" `Quick
            test_a_declined_keep_drops_an_entry_for_another_version
        ; test_case "a forget during the decode is not undone" `Quick
            test_a_forget_during_the_decode_is_not_undone
        ; test_case "an error is not kept" `Quick test_an_error_is_not_kept
        ; test_case "a missing file is decoded every time" `Quick
            test_a_missing_file_is_decoded_every_time
        ] )
    ]
;;
