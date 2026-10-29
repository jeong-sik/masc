(** RFC-0474 L4f: [Audit.read_recent] answers from an index it advances over
    appended bytes, and must give the answer the backward scan it replaced
    gave. [scan] below is that scan: newest row first, stop at the [n]-th
    match, refuse a malformed row, or for a Keeper-scoped read a row that does
    not name exactly one string Keeper, when the scan reaches it.

    One store goes through appends to the newest file, a late append to an
    older file, a new day file, a removed day file, a rewritten day file, a
    malformed row and an unowned row. After each step every Keeper, the
    unscoped read and several [n] are compared. The index is process state,
    so the steps share it as the server's reads do. Other cases: a row without
    a final newline, files rewritten in place on the same inode, and many
    reads at once on several domains. *)

module Audit = Keeper_approval.Audit
open Alcotest

let temp_dir () =
  let dir = Filename.temp_file "test_approval_audit_recent_index_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let rec cleanup_dir path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun name -> cleanup_dir (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
;;

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let audit_dir base_path =
  Filename.concat (Filename.concat base_path ".masc") "audit-approvals"
;;

let day_path ~base_path ~month ~day =
  let dir = Filename.concat (audit_dir base_path) month in
  mkdir_p dir;
  Filename.concat dir day
;;

let append_lines path lines =
  let oc = open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o644 path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> List.iter (fun line -> output_string oc (line ^ "\n")) lines)
;;

let serial = ref 0

let row keeper =
  incr serial;
  Yojson.Safe.to_string
    (`Assoc
        [ "ts", `Float (float_of_int !serial)
        ; "event", `String "pending"
        ; "id", `String (Printf.sprintf "approval-%d" !serial)
        ; "keeper", `String keeper
        ; "tool", `String "tool_execute"
        ])
;;

let rows keeper count = List.init count (fun _ -> row keeper)

(* The backward scan [read_recent] used before the index. *)
let scan ~base_path ?keeper_name ~n () =
  let store =
    Dated_jsonl.open_store
      Dated_jsonl.Store.(at (root_of_base_path ~base_path) Root.Audit_approvals)
  in
  let selected = ref [] in
  let count = ref 0 in
  let select = function
    | Dated_jsonl.Malformed_json _ -> Some (Error "malformed row")
    | Dated_jsonl.Parsed json ->
      let matches =
        match keeper_name with
        | None -> Ok true
        | Some name ->
          (match json with
           | `Assoc fields ->
             (match List.filter (fun (key, _) -> String.equal key "keeper") fields with
              | [ (_, `String owner) ] -> Ok (String.equal name owner)
              | _ -> Error "unowned row")
           | _ -> Error "unowned row")
      in
      (match matches with
       | Error detail -> Some (Error detail)
       | Ok false -> None
       | Ok true ->
         selected := json :: !selected;
         incr count;
         if !count = n then Some (Ok (List.rev !selected)) else None)
  in
  match Dated_jsonl.find_latest_entry_result store select with
  | Error error -> Error (Dated_jsonl.read_error_to_string error)
  | Ok (Some result) -> result
  | Ok None -> Ok (List.rev !selected)
;;

let readers = [ Some "alpha"; Some "beta"; Some "gamma"; Some "absent"; None ]
let sizes = [ 1; 2; 5; 20; Audit.read_recent_max_rows ]

let agrees_with_scan ~base_path step =
  List.iter
    (fun keeper_name ->
       List.iter
         (fun n ->
            let label =
              Printf.sprintf "%s: %s n=%d" step (Option.value ~default:"*" keeper_name) n
            in
            match
              ( Audit.read_recent ~base_path ?keeper_name ~n ()
              , scan ~base_path ?keeper_name ~n () )
            with
            | Ok index, Ok scanned ->
              check int (label ^ " count") (List.length scanned) (List.length index);
              check bool (label ^ " rows") true (List.for_all2 Yojson.Safe.equal index scanned)
            | Error _, Error _ -> ()
            | Ok _, Error detail -> failf "%s: index answered, scan refused (%s)" label detail
            | Error error, Ok _ ->
              failf "%s: index refused (%s), scan answered" label
                (Audit.read_error_to_string error))
         sizes)
    readers
;;

let test_index_answers_as_the_backward_scan () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let path month day = day_path ~base_path ~month ~day in
  let sep30 = path "2026-09" "30.jsonl" in
  let oct01 = path "2026-10" "01.jsonl" in
  let oct02 = path "2026-10" "02.jsonl" in
  (* gamma has rows only in the oldest file, so a gamma read reaches it. *)
  append_lines sep30 (rows "gamma" 3 @ rows "alpha" 10 @ rows "beta" 2);
  append_lines oct01 (rows "alpha" 20 @ rows "beta" 1);
  append_lines oct02 (rows "alpha" 5);
  agrees_with_scan ~base_path "initial";
  agrees_with_scan ~base_path "unchanged";
  (* Newest file, a late append to an older one, a new day file. *)
  append_lines oct02 (rows "beta" 3);
  append_lines oct01 (rows "gamma" 2);
  append_lines (path "2026-10" "03.jsonl") (rows "gamma" 1);
  agrees_with_scan ~base_path "appended";
  (* Removal and rewrite come before any refused row: a refused row newer
     than every read would hide a removed file's rows from the comparison. *)
  Sys.remove sep30;
  agrees_with_scan ~base_path "oldest day file removed";
  let oct03 = path "2026-10" "03.jsonl" in
  Sys.remove oct03;
  append_lines oct03 (rows "gamma" 1);
  agrees_with_scan ~base_path "day file rewritten";
  check bool "the index read the rewritten file" true
    (match Audit.read_recent ~base_path ~keeper_name:"gamma" ~n:1 () with
     | Ok [ `Assoc fields ] ->
       List.assoc_opt "id" fields = Some (`String (Printf.sprintf "approval-%d" !serial))
     | Ok _ | Error _ -> false);
  append_lines oct01 [ "{\"event\": \"pending\", \"keeper\": " ];
  agrees_with_scan ~base_path "malformed row";
  append_lines oct03 [ "{\"event\":\"pending\",\"id\":\"x\"}" ];
  agrees_with_scan ~base_path "unowned row"
;;

let append_raw path text =
  let oc = open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o644 path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc text)
;;

(* The backward scan reads the bytes after the last newline as one more row:
   a complete row is returned, a broken one refuses the reads that reach it.
   The index must answer the same while the row is unfinished and after it
   ends. *)
let test_row_without_a_final_newline () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let file = day_path ~base_path ~month:"2026-10" ~day:"01.jsonl" in
  append_lines file (rows "alpha" 3 @ rows "beta" 1);
  agrees_with_scan ~base_path "complete rows";
  append_raw file (row "alpha");
  agrees_with_scan ~base_path "complete row without a newline";
  agrees_with_scan ~base_path "complete row without a newline, unchanged";
  append_raw file "\n";
  append_lines file (rows "beta" 2);
  agrees_with_scan ~base_path "that row ended";
  append_raw file "{\"event\":\"pending\",\"keeper\":";
  agrees_with_scan ~base_path "broken row without a newline";
  append_raw file "\"alpha\"}\n";
  agrees_with_scan ~base_path "the broken row completed"
;;

(* A day file truncated and rewritten longer on the same inode looks appended
   to a cursor. The index must not keep rows the rewrite removed. *)
let test_file_rewritten_in_place_and_grown () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let file = day_path ~base_path ~month:"2026-10" ~day:"01.jsonl" in
  append_lines file (rows "alpha" 3 @ rows "beta" 2);
  agrees_with_scan ~base_path "before the rewrite";
  let inode = (Unix.stat file).Unix.st_ino in
  let oc = open_out_gen [ Open_wronly; Open_trunc ] 0o644 file in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    List.iter (fun line -> output_string oc (line ^ "\n")) (rows "beta" 12));
  check int "same inode" inode (Unix.stat file).Unix.st_ino;
  agrees_with_scan ~base_path "rewritten in place and grown";
  check bool "alpha's removed rows are gone" true
    (Audit.read_recent ~base_path ~keeper_name:"alpha" ~n:1 () = Ok [])
;;

(* Retention removes the oldest day files, and the index drops their rows
   instead of starting over. alpha has more rows than a window keeps, so a
   window that dropped too many or too few rows shows. The oldest file also
   holds a malformed and an unowned row, which refuse reads until it goes. A
   middle file removed leaves older rows the window displaced, so the index
   must start over. *)
let test_removed_day_files () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let path day = day_path ~base_path ~month:"2026-10" ~day in
  let oct01 = path "01.jsonl" and oct02 = path "02.jsonl" in
  let oct03 = path "03.jsonl" and oct04 = path "04.jsonl" in
  append_lines oct01
    (rows "alpha" 150
     @ [ "{\"event\": \"pending\", \"keeper\": "; "{\"event\":\"pending\",\"id\":\"x\"}" ]
     @ rows "gamma" 2);
  append_lines oct02 (rows "alpha" 100 @ rows "beta" 3);
  append_lines oct03 (rows "alpha" 90 @ rows "beta" 1);
  append_lines oct04 (rows "alpha" 60);
  agrees_with_scan ~base_path "four day files";
  Sys.remove oct01;
  agrees_with_scan ~base_path "the oldest file removed";
  Sys.remove oct03;
  agrees_with_scan ~base_path "a middle file removed";
  Sys.remove oct02;
  Sys.remove oct04;
  agrees_with_scan ~base_path "every file removed";
  append_lines oct04 (rows "beta" 2);
  agrees_with_scan ~base_path "a file written again"
;;

(* An unreadable month stops the listing, as it stops the scan. A file
   removed from a newer month, which is still listed whole, must not keep its
   rows. *)
let test_unreadable_month () =
  let base_path = temp_dir () in
  let september = Filename.concat (audit_dir base_path) "2026-09" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists september then Unix.chmod september 0o755;
      cleanup_dir base_path)
  @@ fun () ->
  append_lines (day_path ~base_path ~month:"2026-09" ~day:"30.jsonl") (rows "gamma" 1);
  append_lines (day_path ~base_path ~month:"2026-10" ~day:"01.jsonl") (rows "alpha" 1);
  let oct02 = day_path ~base_path ~month:"2026-10" ~day:"02.jsonl" in
  append_lines oct02 (rows "alpha" 1);
  agrees_with_scan ~base_path "every month readable";
  Unix.chmod september 0o000;
  check bool "the month cannot be listed" true
    (match Sys.readdir september with
     | _ -> false
     | exception Sys_error _ -> true);
  agrees_with_scan ~base_path "an older month unreadable";
  Sys.remove oct02;
  agrees_with_scan ~base_path "an older month unreadable, a newer file removed";
  Unix.chmod september 0o755;
  agrees_with_scan ~base_path "the month readable again"
;;

(* A row about 1 KB long, so a test file passes a 1 MiB digest block with
   few rows. *)
let padded_row keeper =
  incr serial;
  Yojson.Safe.to_string
    (`Assoc
        [ "ts", `Float (float_of_int !serial)
        ; "event", `String "pending"
        ; "id", `String (Printf.sprintf "approval-%d" !serial)
        ; "keeper", `String keeper
        ; "note", `String (String.make 900 'x')
        ])
;;

let replace_once text ~sub ~by =
  let rec find from =
    if from + String.length sub > String.length text
    then failf "%S not in %S" sub text
    else if String.equal (String.sub text from (String.length sub)) sub
    then from
    else find (from + 1)
  in
  let at = find 0 in
  String.sub text 0 at ^ by
  ^ String.sub text (at + String.length sub) (String.length text - at - String.length sub)
;;

(* Write [lines] over [file] from its first byte, on the same inode, without
   truncating it. *)
let overwrite_in_place file lines =
  let text = String.concat "" (List.map (fun line -> line ^ "\n") lines) in
  let descriptor = Unix.openfile file [ Unix.O_WRONLY ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
    check int "every byte written" (String.length text)
      (Unix.write_substring descriptor text 0 (String.length text)))
;;

(* A rewrite that keeps the bytes just before the last read's boundary and
   grows the file. One row changes owner from alpha to gamma, and the rows
   after it stay as they were: in the first 1 MiB block, and in the last,
   partial block more than 4 KiB before the boundary. The index must read the
   changed row as the scan does. *)
let test_rewrite_that_keeps_the_bytes_before_the_boundary () =
  let row_count = 1600 in
  List.iter
    (fun (label, changed_line) ->
       let base_path = temp_dir () in
       Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
       let file = day_path ~base_path ~month:"2026-10" ~day:"01.jsonl" in
       let lines = List.init row_count (fun _ -> padded_row "alpha") in
       append_lines file lines;
       check bool (label ^ ": the file passes one digest block") true
         ((Unix.stat file).Unix.st_size > 1_048_576);
       agrees_with_scan ~base_path (label ^ ": before the rewrite");
       let inode = (Unix.stat file).Unix.st_ino in
       let changed =
         List.mapi
           (fun index line ->
              if index = changed_line
              then replace_once line ~sub:"\"keeper\":\"alpha\"" ~by:"\"keeper\":\"gamma\""
              else line)
           lines
       in
       overwrite_in_place file (changed @ List.init 3 (fun _ -> padded_row "beta"));
       check int (label ^ ": same inode") inode (Unix.stat file).Unix.st_ino;
       agrees_with_scan ~base_path (label ^ ": rewritten and grown");
       check int (label ^ ": gamma's row is read") 1
         (match Audit.read_recent ~base_path ~keeper_name:"gamma" ~n:1 () with
          | Ok rows -> List.length rows
          | Error error -> failf "gamma refused: %s" (Audit.read_error_to_string error)))
    [ "first block", 0; "last block", row_count - 20 ]
;;

(* Reads that arrive together share one advance. Several fibers on each of
   several domains read at once, through the first build, appends, an
   in-place rewrite and a new day file. The store does not change during a
   round, so every read must give the scan's answer. Mismatches are collected
   and checked after the domains join. *)
let test_concurrent_reads_agree_with_the_scan () =
  let domains = 4 in
  let fibers_per_domain = 10 in
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let oct01 = day_path ~base_path ~month:"2026-10" ~day:"01.jsonl" in
  let oct02 = day_path ~base_path ~month:"2026-10" ~day:"02.jsonl" in
  append_lines oct01 (rows "alpha" 40 @ rows "gamma" 3 @ rows "beta" 30);
  append_lines oct02 (rows "alpha" 10);
  Eio_main.run @@ fun env ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let round step =
    let expected =
      List.map (fun keeper_name -> keeper_name, scan ~base_path ?keeper_name ~n:20 ()) readers
    in
    let mismatches = Atomic.make [] in
    let rec note mismatch =
      let seen = Atomic.get mismatches in
      if not (Atomic.compare_and_set mismatches seen (mismatch :: seen)) then note mismatch
    in
    let read_once index () =
      let keeper_name = List.nth readers (index mod List.length readers) in
      let label = Option.value ~default:"*" keeper_name in
      match Audit.read_recent ~base_path ?keeper_name ~n:20 (), List.assoc keeper_name expected with
      | Ok index_rows, Ok scanned
        when List.length index_rows = List.length scanned
             && List.for_all2 Yojson.Safe.equal index_rows scanned -> ()
      | Error _, Error _ -> ()
      | Ok _, Ok _ -> note (label ^ ": other rows")
      | Ok _, Error _ -> note (label ^ ": index answered, scan refused")
      | Error error, Ok _ ->
        note (label ^ ": index refused: " ^ Audit.read_error_to_string error)
    in
    Eio.Fiber.all
      (List.init domains (fun _ () ->
         Eio.Domain_manager.run domain_mgr (fun () ->
           Eio.Fiber.all (List.init fibers_per_domain read_once))));
    check (list string) (step ^ ": every read agrees with the scan") [] (Atomic.get mismatches)
  in
  round "first build";
  round "unchanged";
  append_lines oct02 (rows "beta" 5 @ rows "gamma" 1);
  round "appended";
  overwrite_in_place oct01 (rows "gamma" 60 @ rows "beta" 20);
  round "rewritten in place";
  append_lines (day_path ~base_path ~month:"2026-10" ~day:"03.jsonl") (rows "alpha" 2);
  round "new day file"
;;

(* A read must see every row appended before it began, even when it arrives
   while another read's advance is running: that advance may have listed the
   file before the row landed. One domain appends alpha rows one by one and
   publishes each row's serial once its append returns; readers on other
   domains note the published serial, read alpha's newest row, and that row's
   serial must be at least the noted one. A refused read (a reader can see a
   row half written) is counted apart and proves nothing. *)
let test_a_read_sees_rows_appended_before_it () =
  let appends = 300 in
  let reader_domains = 3 in
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let file = day_path ~base_path ~month:"2026-10" ~day:"01.jsonl" in
  append_lines file (rows "beta" 50);
  let serial_of = function
    | `Assoc fields ->
      (match List.assoc_opt "id" fields with
       | Some (`String id) -> Scanf.sscanf_opt id "approval-%d%!" Fun.id
       | Some _ | None -> None)
    | _ -> None
  in
  let published = Atomic.make 0 in
  let writing = Atomic.make true in
  let stale = Atomic.make 0 in
  let answered = Atomic.make 0 in
  Eio_main.run @@ fun env ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let write () =
    for _ = 1 to appends do
      append_lines file [ row "alpha" ];
      Atomic.set published !serial
    done;
    Atomic.set writing false
  in
  let read () =
    while Atomic.get writing do
      let before = Atomic.get published in
      match Audit.read_recent ~base_path ~keeper_name:"alpha" ~n:1 () with
      | Ok [ newest ] ->
        Atomic.incr answered;
        (match serial_of newest with
         | Some serial when serial >= before -> ()
         | Some _ | None -> Atomic.incr stale)
      | Ok [] -> if before > 0 then Atomic.incr stale
      | Ok (_ :: _ :: _) -> Atomic.incr stale
      | Error _ -> ()
    done
  in
  Eio.Fiber.all
    ((fun () -> Eio.Domain_manager.run domain_mgr write)
     :: List.init reader_domains (fun _ () -> Eio.Domain_manager.run domain_mgr read));
  check int "reads older than a row appended before them" 0 (Atomic.get stale);
  check bool "some reads answered while rows were appended" true (Atomic.get answered > 0)
;;

(* The same rule without racing: a read that arrives while a long first
   build runs must not take that build's answer, because the build opened the
   file before the row it wants was appended. One domain starts building
   from a 30 MB file; 20 ms later a row is appended and another read starts.
   The test fails rather than proves nothing if the build is already over. *)
let test_a_read_during_a_build_sees_a_row_appended_before_it () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let file = day_path ~base_path ~month:"2026-10" ~day:"01.jsonl" in
  append_lines file (List.init 30_000 (fun _ -> padded_row "beta"));
  let build_done = Atomic.make false in
  Eio_main.run @@ fun env ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  Eio.Switch.run @@ fun sw ->
  let build =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Eio.Domain_manager.run domain_mgr (fun () ->
        let answer = Audit.read_recent ~base_path ~keeper_name:"alpha" ~n:1 () in
        Atomic.set build_done true;
        answer))
  in
  Eio.Time.sleep (Eio.Stdenv.clock env) 0.02;
  append_lines file [ row "alpha" ];
  let appended = Printf.sprintf "approval-%d" !serial in
  check bool "the build still runs when the row is appended" false (Atomic.get build_done);
  let later = Audit.read_recent ~base_path ~keeper_name:"alpha" ~n:1 () in
  ignore (Eio.Promise.await_exn build);
  check bool "the later read has the appended row" true
    (match later with
     | Ok [ `Assoc fields ] -> List.assoc_opt "id" fields = Some (`String appended)
     | Ok _ | Error _ -> false)
;;

(* With a pool, a read outside it must not run an advance another read is
   waiting for inside a pool job. One worker: a pool job holds it, a read
   outside the pool arrives, then the pool job reads. If the outside read ran
   the advance, it would wait for the worker the job holds while the job
   waits for that advance. *)
let test_reads_inside_and_outside_a_one_worker_pool () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  append_lines (day_path ~base_path ~month:"2026-10" ~day:"01.jsonl")
    (rows "alpha" 5 @ rows "beta" 2);
  let expected = scan ~base_path ~keeper_name:"alpha" ~n:3 () in
  let read () =
    Audit.read_recent ~base_path ~keeper_name:"alpha" ~n:3 ()
    |> Result.map_error Audit.read_error_to_string
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  let started, job_started = Eio.Promise.create () in
  let go, release_job = Eio.Promise.create () in
  let answers =
    Eio.Time.with_timeout (Eio.Stdenv.clock env) 30.0 (fun () ->
      Eio.Fiber.pair
        (fun () ->
           Domain_pool.submit_cpu ~name:"holds the worker" pool (fun () ->
             Eio.Promise.resolve job_started ();
             Eio.Promise.await go;
             read ()))
        (fun () ->
           Eio.Promise.await started;
           Eio.Fiber.both
             (fun () -> ignore (read ()))
             (fun () -> Eio.Promise.resolve release_job ());
           read ())
      |> Result.ok)
  in
  match answers with
  | Error `Timeout -> fail "the reads waited for each other"
  | Ok (inside, outside) ->
    let agrees label answer =
      match answer, expected with
      | Ok rows, Ok scanned ->
        check int (label ^ " count") (List.length scanned) (List.length rows);
        check bool (label ^ " rows") true (List.for_all2 Yojson.Safe.equal rows scanned)
      | Error _, Error _ -> ()
      | Ok _, Error detail -> failf "%s: index answered, scan refused (%s)" label detail
      | Error detail, Ok _ -> failf "%s: index refused (%s)" label detail
    in
    agrees "the read inside the pool job" inside;
    agrees "the read outside the pool" outside
;;

let test_bounds () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  append_lines (day_path ~base_path ~month:"2026-10" ~day:"01.jsonl") (rows "alpha" 2);
  check bool "n <= 0 reads nothing" true
    (Audit.read_recent ~base_path ~keeper_name:"alpha" ~n:0 () = Ok []);
  check bool "n above the kept rows is refused" true
    (Result.is_error
       (Audit.read_recent ~base_path ~keeper_name:"alpha"
          ~n:(Audit.read_recent_max_rows + 1) ()));
  check int "a missing store reads empty" 0
    (match Audit.read_recent ~base_path:(Filename.concat base_path "nowhere") ~n:5 () with
     | Ok rows -> List.length rows
     | Error error -> failf "missing store refused: %s" (Audit.read_error_to_string error))
;;

let () =
  run "approval_audit_recent_index"
    [ ( "read_recent"
      , [ test_case "answers as the backward scan through store changes" `Quick
            test_index_answers_as_the_backward_scan
        ; test_case "a row without a final newline" `Quick test_row_without_a_final_newline
        ; test_case "removed day files" `Quick test_removed_day_files
        ; test_case "an unreadable month" `Quick test_unreadable_month
        ; test_case "a file rewritten in place and grown" `Quick
            test_file_rewritten_in_place_and_grown
        ; test_case "a rewrite that keeps the bytes before the boundary" `Quick
            test_rewrite_that_keeps_the_bytes_before_the_boundary
        ; test_case "concurrent reads agree with the scan" `Quick
            test_concurrent_reads_agree_with_the_scan
        ; test_case "a read sees rows appended before it" `Quick
            test_a_read_sees_rows_appended_before_it
        ; test_case "a read during a build sees a row appended before it" `Quick
            test_a_read_during_a_build_sees_a_row_appended_before_it
        ; test_case "reads inside and outside a one-worker pool" `Quick
            test_reads_inside_and_outside_a_one_worker_pool
        ; test_case "bounds" `Quick test_bounds
        ] )
    ]
;;
