(* A keeper's raw traces become readable from outside the host for the first
   time here, so the properties under test are the ones that decide whether the
   surface can be trusted with a caller-supplied name: it cannot be made to read
   a file outside the keeper's directory, an unparseable line keeps its place
   instead of vanishing, and an absent keeper directory is an empty answer
   rather than an error. *)

module Reader = Masc.Keeper_raw_trace_reader
module Support = Masc.Keeper_types_support

let keeper = "test-keeper"

let temp_dir () =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-rawtrace-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir path 0o700;
  path
;;

let rec rm_rf path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun e -> rm_rf (Filename.concat path e));
    (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> (try Unix.unlink path with Unix.Unix_error _ -> ())
  | exception Unix.Unix_error _ -> ()
;;

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700)
;;

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let out = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out out) (fun () -> output_string out contents)
;;

(* A workspace whose keeper holds [turns], each a list of raw JSONL lines. *)
let with_traces turns f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  let trace_dir = Support.keeper_raw_trace_dir config keeper in
  mkdir_p trace_dir;
  List.iter
    (fun (name, lines) ->
       write_file (Filename.concat trace_dir name) (String.concat "\n" lines ^ "\n"))
    turns;
  f config trace_dir
;;

let line seq record_type =
  Printf.sprintf {|{"seq":%d,"record_type":"%s"}|} seq record_type
;;

let ok_records records =
  List.filter_map (function Ok json -> Some json | Error _ -> None) records
;;

let test_lists_turns_newest_first () =
  with_traces
    [ "turn-100" ^ Support.raw_trace_file_extension, [ line 1 "run_started" ]
    ; ( "turn-300" ^ Support.raw_trace_file_extension
      , [ line 1 "run_started"; line 2 "run_finished" ] )
    ]
    (fun config trace_dir ->
       (* mtime decides the order, so make the intended newest actually newer
          rather than relying on write order the filesystem may not preserve. *)
       let older = Filename.concat trace_dir ("turn-100" ^ Support.raw_trace_file_extension) in
       Unix.utimes older 1.0 1.0;
       match Reader.list_turns ~config ~keeper ~limit:10 with
       | Error error -> Alcotest.failf "list failed: %s" (Reader.read_error_to_string error)
       | Ok turns ->
         Alcotest.(check (list string))
           "newest first"
           [ "turn-300" ^ Support.raw_trace_file_extension
           ; "turn-100" ^ Support.raw_trace_file_extension
           ]
           (List.map (fun (t : Reader.turn_summary) -> t.file) turns);
         Alcotest.(check int)
           "record count is non-blank lines"
           2
           (match turns with t :: _ -> t.records | [] -> -1))
;;

let test_absent_keeper_directory_is_empty_not_error () =
  with_traces [] (fun config _dir ->
    match Reader.list_turns ~config ~keeper:"never-ran" ~limit:10 with
    | Ok [] -> ()
    | Ok turns -> Alcotest.failf "expected no turns, got %d" (List.length turns)
    | Error error ->
      Alcotest.failf
        "a keeper that never ran must not be an error: %s"
        (Reader.read_error_to_string error))
;;

(* The file name is a handle, not a path. Every shape below would reach outside
   the keeper's directory if it were joined and normalized. *)
let test_file_name_cannot_escape_the_keeper_directory () =
  with_traces
    [ "turn-1" ^ Support.raw_trace_file_extension, [ line 1 "run_started" ] ]
    (fun config trace_dir ->
       let outside =
         Filename.concat (Filename.dirname trace_dir) ("secret" ^ Support.raw_trace_file_extension)
       in
       write_file outside (line 1 "leaked" ^ "\n");
       List.iter
         (fun candidate ->
            match Reader.read_turn ~config ~keeper ~file:candidate ~offset:0 ~limit:10 with
            | Ok _ -> Alcotest.failf "%S must not resolve" candidate
            | Error _ -> ())
         [ "../secret" ^ Support.raw_trace_file_extension
         ; "../../etc/passwd" ^ Support.raw_trace_file_extension
         ; "subdir/turn-1" ^ Support.raw_trace_file_extension
         ; ".."
         ; "."
         ; ""
         ])
;;

(* A name inside the directory but of the wrong kind is refused too: the
   extension is what marks a file as a raw trace, and reading anything else in
   that directory would be reading a file this surface never described. *)
let test_non_trace_extension_is_refused () =
  with_traces [] (fun config trace_dir ->
    write_file (Filename.concat trace_dir "notes.txt") "not a trace\n";
    match Reader.read_turn ~config ~keeper ~file:"notes.txt" ~offset:0 ~limit:10 with
    | Ok _ -> Alcotest.fail "a non-trace extension must not resolve"
    | Error error ->
      Alcotest.(check bool)
        "the reason names the expected extension"
        true
        (Astring.String.is_infix
           ~affix:Support.raw_trace_file_extension
           (Reader.read_error_to_string error)))
;;

let test_missing_turn_is_its_own_error () =
  with_traces [] (fun config _dir ->
    match
      Reader.read_turn
        ~config
        ~keeper
        ~file:("turn-absent" ^ Support.raw_trace_file_extension)
        ~offset:0
        ~limit:10
    with
    | Ok _ -> Alcotest.fail "a missing turn must not resolve"
    | Error (Reader.No_such_turn _) -> ()
    | Error error ->
      Alcotest.failf
        "expected No_such_turn, got %s"
        (Reader.read_error_to_string error))
;;

(* A torn line is an observation. Dropping it would make a damaged trace read as
   a shorter one, and the operator reading it is the one who has to tell those
   apart. *)
let test_unparseable_line_keeps_its_position () =
  with_traces
    [ ( "turn-1" ^ Support.raw_trace_file_extension
      , [ line 1 "run_started"; "{not json"; line 3 "run_finished" ] )
    ]
    (fun config _dir ->
       match
         Reader.read_turn
           ~config
           ~keeper
           ~file:("turn-1" ^ Support.raw_trace_file_extension)
           ~offset:0
           ~limit:10
       with
       | Error error -> Alcotest.failf "read failed: %s" (Reader.read_error_to_string error)
       | Ok records ->
         Alcotest.(check int) "total counts the torn line" 3 records.total_records;
         Alcotest.(check int) "all three positions returned" 3 (List.length records.records);
         Alcotest.(check int) "exactly one is unparseable" 2 (List.length (ok_records records.records));
         (match records.records with
          | [ Ok _; Error _; Ok _ ] -> ()
          | _ -> Alcotest.fail "the torn line must occupy position 2"))
;;

let test_offset_and_limit_window_the_file () =
  with_traces
    [ ( "turn-1" ^ Support.raw_trace_file_extension
      , List.init 10 (fun i -> line (i + 1) "assistant_block") )
    ]
    (fun config _dir ->
       match
         Reader.read_turn
           ~config
           ~keeper
           ~file:("turn-1" ^ Support.raw_trace_file_extension)
           ~offset:4
           ~limit:3
       with
       | Error error -> Alcotest.failf "read failed: %s" (Reader.read_error_to_string error)
       | Ok records ->
         Alcotest.(check int) "total is the whole file" 10 records.total_records;
         Alcotest.(check int) "offset is echoed" 4 records.offset;
         Alcotest.(check int) "limit bounds the window" 3 (List.length records.records);
         let seqs =
           ok_records records.records
           |> List.map (fun json ->
             Yojson.Safe.Util.(json |> member "seq" |> to_int))
         in
         Alcotest.(check (list int)) "the window starts at offset" [ 5; 6; 7 ] seqs)
;;

let test_invalid_keeper_name_is_refused () =
  with_traces [] (fun config _dir ->
    match Reader.list_turns ~config ~keeper:"../escape" ~limit:10 with
    | Ok _ -> Alcotest.fail "an invalid keeper name must not resolve"
    | Error (Reader.Unknown_keeper _) -> ()
    | Error error ->
      Alcotest.failf
        "expected Unknown_keeper, got %s"
        (Reader.read_error_to_string error))
;;

let () =
  Random.self_init ();
  Alcotest.run
    "keeper raw trace reader"
    [ ( "containment"
      , [ Alcotest.test_case "file name cannot escape the keeper directory" `Quick
            test_file_name_cannot_escape_the_keeper_directory
        ; Alcotest.test_case "non-trace extension is refused" `Quick
            test_non_trace_extension_is_refused
        ; Alcotest.test_case "invalid keeper name is refused" `Quick
            test_invalid_keeper_name_is_refused
        ] )
    ; ( "listing"
      , [ Alcotest.test_case "lists turns newest first" `Quick
            test_lists_turns_newest_first
        ; Alcotest.test_case "absent keeper directory is empty, not error" `Quick
            test_absent_keeper_directory_is_empty_not_error
        ] )
    ; ( "reading"
      , [ Alcotest.test_case "missing turn is its own error" `Quick
            test_missing_turn_is_its_own_error
        ; Alcotest.test_case "unparseable line keeps its position" `Quick
            test_unparseable_line_keeps_its_position
        ; Alcotest.test_case "offset and limit window the file" `Quick
            test_offset_and_limit_window_the_file
        ] )
    ]
;;
