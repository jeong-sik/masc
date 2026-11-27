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

(* A writer that renames a new file into place, so the path gets a new inode. *)
let replace path contents =
  let replacement = path ^ ".next" in
  write replacement contents;
  Unix.rename replacement path
;;

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

let test_an_unrelated_write_leaves_a_fill_kept () =
  with_file (fun path -> with_file (fun other ->
    write path "one";
    write other "a";
    let cache = File_version_cache.create () in
    let runs = ref 0 in
    let decode () =
      incr runs;
      replace other "b";
      File_version_cache.forget cache other;
      Ok (read path)
    in
    ignore (load cache path ~decode : string);
    check string "reuses the unchanged file" "one" (load cache path ~decode);
    check int "one decode despite a write to the other file" 1 !runs))
;;

(* After observing a distinct version, the old value is gone even when the
   newer read fails and the original file stamp later reappears. *)
let test_a_failed_fill_drops_the_previous_version () =
  with_file
  @@ fun path ->
  write path "one";
  pin_mtime path pinned_mtime;
  let cache = File_version_cache.create () in
  let runs = ref 0 in
  let decode () =
    incr runs;
    if !runs = 2 then Error () else Ok (read path)
  in
  check string "the first version is kept" "one" (load cache path ~decode);
  write path "two";
  pin_mtime path (pinned_mtime +. 1.0);
  check bool "the changed file was unreadable" true
    (Result.is_error (File_version_cache.load cache path ~decode));
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

let test_a_changed_file_drops_a_concurrent_fill () =
  with_file
  @@ fun path ->
  write path "one";
  pin_mtime path pinned_mtime;
  let cache = File_version_cache.create () in
  let decode, runs = counting_decode path in
  let overlapping_read () =
    let old = load cache path ~decode in
    write path "two";
    pin_mtime path (pinned_mtime +. 1.0);
    Ok old
  in
  check string "the overlapping read returns its own observation" "one"
    (load cache path ~decode:overlapping_read);
  write path "six";
  pin_mtime path pinned_mtime;
  check string "the earlier stamp does not restore a stale fill" "six" (load cache path ~decode);
  check int "the restored stamp is decoded" 2 !runs
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

(* A writer that replaced the file keeps the value it wrote: the next read
   takes it and decodes nothing. *)
let test_a_written_value_is_read_without_decoding () =
  with_file
  @@ fun path ->
  write path "one";
  let cache = File_version_cache.create () in
  let decode, runs = counting_decode path in
  ignore (load cache path ~decode : string);
  replace path "two";
  let written = "two" in
  File_version_cache.keep_written cache path written;
  check bool "the read takes the written value" true (load cache path ~decode == written);
  check int "and the write was not decoded" 1 !runs
;;

(* The kept value belongs to the version the writer left. A later replacement
   by a writer that tells the cache nothing is decoded. *)
let test_a_file_replaced_after_a_kept_write_is_decoded () =
  with_file
  @@ fun path ->
  write path "one";
  let cache = File_version_cache.create () in
  let decode, runs = counting_decode path in
  File_version_cache.keep_written cache path "one";
  replace path "two";
  check string "the read decodes the replacement" "two" (load cache path ~decode);
  check int "once" 1 !runs
;;

(* A decode that was reading the old file while the writer replaced it does
   not put its value over the one the writer kept. *)
let test_a_decode_overtaken_by_a_kept_write_keeps_nothing () =
  with_file
  @@ fun path ->
  write path "one";
  let cache = File_version_cache.create () in
  let overtaken () =
    let old = read path in
    replace path "two";
    File_version_cache.keep_written cache path "two";
    Ok old
  in
  check string "the overtaken read returns what it decoded" "one"
    (load cache path ~decode:overtaken);
  let decode, runs = counting_decode path in
  check string "the next read takes the written value" "two" (load cache path ~decode);
  check int "without decoding" 0 !runs
;;

(* A path that is gone has no version to keep a value for. *)
let test_a_written_value_for_a_missing_file_is_not_kept () =
  with_file
  @@ fun path ->
  let cache = File_version_cache.create () in
  File_version_cache.keep_written cache path "gone";
  write path "one";
  let decode, runs = counting_decode path in
  check string "the read decodes the file" "one" (load cache path ~decode);
  check int "once" 1 !runs
;;

let test_hot_hits_across_many_files_reuse_kept_values () =
  let dir = Filename.temp_dir "file_version_cache_many" "" in
  let count = 128 in
  let paths =
    Array.init count (fun i -> Filename.concat dir (Printf.sprintf "doc-%03d" i))
  in
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun p -> try Sys.remove p with Sys_error _ -> ()) paths;
      try Sys.rmdir dir with Sys_error _ -> ())
    (fun () ->
      Array.iteri (fun i p -> write p (Printf.sprintf "payload-%03d" i)) paths;
      let cache = File_version_cache.create () in
      let runs = ref 0 in
      let decode_path p () =
        incr runs;
        Ok (read p)
      in
      let first = Array.map (fun p -> load cache p ~decode:(decode_path p)) paths in
      check int "cold fill decodes each file once" count !runs;
      for _ = 1 to 10 do
        Array.iteri
          (fun i p ->
            let got = load cache p ~decode:(decode_path p) in
            check bool "hot hit returns physically identical value" true (got == first.(i)))
          paths
      done;
      check int "hot hits perform zero additional decodes" count !runs;
      replace paths.(42) "payload-042-updated";
      check string "replaced file decodes new content" "payload-042-updated"
        (load cache paths.(42) ~decode:(decode_path paths.(42)));
      check int "only the replaced file re-decoded" (count + 1) !runs;
      check bool "neighboring file still hits fast path" true
        (load cache paths.(41) ~decode:(decode_path paths.(41)) == first.(41)))
;;

(* Concurrent readers hitting the fast path while a single serialized writer
   replaces the file and calls [keep_written] must never displace the writer's
   published entry. *)
let test_concurrent_hot_hits_and_keep_written_never_displace () =
  with_file
  @@ fun path ->
  write path "gen-000";
  let cache = File_version_cache.create () in
  let initial = load cache path ~decode:(fun () -> Ok (read path)) in
  check string "seeded" "gen-000" initial;
  let stop = Atomic.make false in
  let reader_error = Atomic.make None in
  let spawn_reader () =
    Domain.spawn (fun () ->
      while not (Atomic.get stop) do
        match File_version_cache.load cache path ~decode:(fun () -> Ok (read path)) with
        | Ok v ->
          if not (String.starts_with ~prefix:"gen-" v) then
            Atomic.set reader_error (Some ("unexpected value: " ^ v))
        | Error () -> Atomic.set reader_error (Some "unexpected error")
      done)
  in
  let r1 = spawn_reader () in
  let r2 = spawn_reader () in
  let final_payload = ref "gen-000" in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set stop true;
      Domain.join r1;
      Domain.join r2)
    (fun () ->
      for i = 1 to 200 do
        let payload = Printf.sprintf "gen-%03d" i in
        replace path payload;
        File_version_cache.keep_written cache path payload;
        final_payload := payload
      done);
  (match Atomic.get reader_error with
   | None -> ()
   | Some msg -> fail msg);
  let decode, runs = counting_decode path in
  let after = load cache path ~decode in
  check string "final written value observed" !final_payload after;
  check bool "fast path serves the exact published string" true (after == !final_payload);
  check int "final keep_written was never displaced" 0 !runs
;;

(* Concurrent readers hitting the fast path while a writer overwrites in place
   with a pinned mtime and calls [forget] must observe the latest value after
   the writer finishes. *)
let test_concurrent_hot_hits_and_in_place_forget_see_latest () =
  with_file
  @@ fun path ->
  write path "v-000";
  pin_mtime path pinned_mtime;
  let cache = File_version_cache.create () in
  ignore (load cache path ~decode:(fun () -> Ok (read path)) : string);
  let stop = Atomic.make false in
  let overwrite_in_place payload =
    Out_channel.with_open_gen [ Open_wronly; Open_binary ] 0o600 path (fun ch ->
      seek_out ch 0;
      output_string ch payload)
  in
  let spawn_reader () =
    Domain.spawn (fun () ->
      while not (Atomic.get stop) do
        ignore
          (File_version_cache.load cache path ~decode:(fun () ->
             let s = read path in
             if String.length s = 5 then Ok s else Error ())
           : (string, unit) result)
      done)
  in
  let r1 = spawn_reader () in
  let r2 = spawn_reader () in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set stop true;
      Domain.join r1;
      Domain.join r2)
    (fun () ->
      for i = 1 to 100 do
        let payload = Printf.sprintf "v-%03d" i in
        overwrite_in_place payload;
        pin_mtime path pinned_mtime;
        File_version_cache.forget cache path
      done);
  let decode, runs = counting_decode path in
  check string "post-forget read observes final in-place write" "v-100"
    (load cache path ~decode);
  let runs_after_first = !runs in
  check bool "at most one decode if a concurrent reader already refreshed v-100" true
    (runs_after_first <= 1);
  check string "subsequent read hits fast path" "v-100" (load cache path ~decode);
  check int "cached without extra decode" runs_after_first !runs;
  File_version_cache.forget cache path;
  check string "explicit forget forces fresh decode" "v-100" (load cache path ~decode);
  check int "decoded once after explicit forget" (runs_after_first + 1) !runs
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
        ; test_case "an unrelated write leaves a fill kept" `Quick
            test_an_unrelated_write_leaves_a_fill_kept
        ; test_case "a failed fill drops the previous version" `Quick
            test_a_failed_fill_drops_the_previous_version
        ; test_case "a changed file drops a concurrent fill" `Quick
            test_a_changed_file_drops_a_concurrent_fill
        ; test_case "a forget during the decode is not undone" `Quick
            test_a_forget_during_the_decode_is_not_undone
        ; test_case "an error is not kept" `Quick test_an_error_is_not_kept
        ; test_case "a missing file is decoded every time" `Quick
            test_a_missing_file_is_decoded_every_time
        ; test_case "hot hits across many files reuse kept values" `Quick
            test_hot_hits_across_many_files_reuse_kept_values
        ; test_case "concurrent hot hits and keep_written never displace" `Quick
            test_concurrent_hot_hits_and_keep_written_never_displace
        ; test_case "concurrent hot hits and in-place forget see latest" `Quick
            test_concurrent_hot_hits_and_in_place_forget_see_latest
        ] )
    ; ( "keep_written"
      , [ test_case "a written value is read without decoding" `Quick
            test_a_written_value_is_read_without_decoding
        ; test_case "a file replaced after a kept write is decoded" `Quick
            test_a_file_replaced_after_a_kept_write_is_decoded
        ; test_case "a decode overtaken by a kept write keeps nothing" `Quick
            test_a_decode_overtaken_by_a_kept_write_keeps_nothing
        ; test_case "a written value for a missing file is not kept" `Quick
            test_a_written_value_for_a_missing_file_is_not_kept
        ] )
    ]
;;
