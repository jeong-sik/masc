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

let line ?session_id seq record_type =
  let session =
    match session_id with
    | None -> ""
    | Some value -> Printf.sprintf {|,"session_id":"%s"|} value
  in
  Printf.sprintf {|{"seq":%d,"record_type":"%s"%s}|} seq record_type session
;;

let ok_records records =
  List.filter_map
    (fun (record : Reader.turn_record) ->
       match record.parsed with
       | Ok json -> Some json
       | Error _ -> None)
    records
;;

let test_lists_turns_newest_first () =
  with_traces
    [ ( "turn-100" ^ Support.raw_trace_file_extension
      , [ line ~session_id:"trace-100" 1 "run_started" ] )
    ; ( "turn-300" ^ Support.raw_trace_file_extension
      , [ line ~session_id:"trace-300" 1 "run_started"
        ; line ~session_id:"trace-300" 2 "run_finished"
        ] )
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
           (match turns with
            | { census = Reader.Whole_file { records }; _ } :: _ -> records
            | { census = Reader.Prefix_only _; _ } :: _ ->
              Alcotest.fail "a two-line turn fits the listing budget"
            | [] -> -1);
         Alcotest.(check (option string))
           "listing carries the exact retained session id"
           (Some "trace-300")
           (match turns with t :: _ -> t.trace_id | [] -> None))
;;

(* A turn far larger than the listing budget. The tail carries a *different*
   session id, which the whole-file listing rejected as a mixed identity — so
   this listing succeeding is behavioural proof that the bytes past the budget
   were never read, not just that a constant changed. One runaway turn on the
   author's host reached 372.5 MB and made this call take 3.35 s for every
   operator who opened the panel. *)
let test_listing_does_not_read_past_the_budget () =
  let padding_line seq =
    Printf.sprintf
      {|{"seq":%d,"record_type":"pad","session_id":"trace-big","pad":"%s"}|}
      seq
      (String.make 4096 'x')
  in
  let head = line ~session_id:"trace-big" 1 "run_started" in
  let padding = List.init 160 (fun index -> padding_line (index + 2)) in
  let tail_from_another_turn = line ~session_id:"trace-other" 999 "run_finished" in
  with_traces
    [ ( "turn-runaway" ^ Support.raw_trace_file_extension
      , (head :: padding) @ [ tail_from_another_turn ] )
    ]
    (fun config trace_dir ->
       let path =
         Filename.concat trace_dir ("turn-runaway" ^ Support.raw_trace_file_extension)
       in
       let size = (Unix.stat path).st_size in
       Alcotest.(check bool)
         "fixture must exceed the listing budget for this test to mean anything"
         true
         (size > 256 * 1024);
       match Reader.list_turns ~config ~keeper ~limit:10 with
       | Error error ->
         Alcotest.failf
           "a turn larger than the budget must still list: %s"
           (Reader.read_error_to_string error)
       | Ok [ turn ] ->
         (match turn.census with
          | Reader.Whole_file { records } ->
            Alcotest.failf "expected an uncounted census, got %d records" records
          | Reader.Prefix_only { budget_bytes } ->
            Alcotest.(check int) "census names the budget it stopped at" (256 * 1024) budget_bytes);
         Alcotest.(check int) "bytes is the whole-file size, not the prefix" size turn.bytes;
         Alcotest.(check (option string))
           "identity comes from the first record"
           (Some "trace-big")
           turn.trace_id;
         (* The count the listing declined to take is still available from the
            read path, which reads the file in full. *)
         (match Reader.read_turn ~config ~keeper ~file:turn.file ~offset:0 ~limit:1 with
          | Error error ->
            Alcotest.failf "read_turn must serve it: %s" (Reader.read_error_to_string error)
          | Ok page ->
            Alcotest.(check int) "read_turn counts every record" 162 page.total_records)
       | Ok turns -> Alcotest.failf "expected one turn, got %d" (List.length turns))
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

let test_mixed_session_ids_reject_the_listing () =
  with_traces
    [ ( "turn-mixed" ^ Support.raw_trace_file_extension
      , [ line ~session_id:"trace-a" 1 "run_started"
        ; line ~session_id:"trace-b" 2 "run_finished"
        ] )
    ]
    (fun config _trace_dir ->
       match Reader.list_turns ~config ~keeper ~limit:10 with
       | Error (Reader.Invalid_trace_record { line = 2; _ }) -> ()
       | Error error ->
         Alcotest.failf "wrong listing failure: %s" (Reader.read_error_to_string error)
       | Ok _ -> Alcotest.fail "mixed sessions must reject the listing")
;;

let test_missing_malformed_and_invalid_trace_ids_reject_the_listing () =
  List.iter
    (fun (label, raw) ->
       with_traces
         [ "turn-invalid" ^ Support.raw_trace_file_extension, [ raw ] ]
         (fun config _trace_dir ->
            match Reader.list_turns ~config ~keeper ~limit:10 with
            | Error (Reader.Invalid_trace_record { line = 1; _ }) -> ()
            | Error error ->
              Alcotest.failf "%s had wrong failure: %s" label
                (Reader.read_error_to_string error)
            | Ok _ -> Alcotest.failf "%s must reject the listing" label))
    [ "missing session", line 1 "run_started"
    ; "malformed JSON", "{not json"
    ; "invalid typed trace id", line ~session_id:"trace.with.dot" 1 "run_started"
    ; ( "duplicate session"
      , {|{"seq":1,"session_id":"trace-a","session_id":"trace-a"}|} )
    ]
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

let test_symlink_trace_is_rejected_for_listing_and_read () =
  with_traces [] (fun config trace_dir ->
    let outside = Filename.concat (Filename.dirname trace_dir) "outside.jsonl" in
    let file = "turn-link" ^ Support.raw_trace_file_extension in
    write_file outside (line ~session_id:"trace-link" 1 "run_started" ^ "\n");
    Unix.symlink outside (Filename.concat trace_dir file);
    (match Reader.list_turns ~config ~keeper ~limit:10 with
     | Error (Reader.Read_failed _) -> ()
     | Error error ->
       Alcotest.failf "symlink listing had wrong failure: %s"
         (Reader.read_error_to_string error)
     | Ok _ -> Alcotest.fail "symlink trace must reject the listing");
    match Reader.read_turn ~config ~keeper ~file ~offset:0 ~limit:10 with
    | Error (Reader.Read_failed _) -> ()
    | Error error ->
      Alcotest.failf "symlink read had wrong failure: %s"
        (Reader.read_error_to_string error)
    | Ok _ -> Alcotest.fail "symlink trace must not be read")
;;

let bearer_request token =
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list [ "authorization", "Bearer " ^ token ])
    `GET
    "/api/v1/keepers/test-keeper/raw-traces"
;;

let create_token_exn base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok (token, _) -> token
  | Error error -> Alcotest.fail (Masc_domain.masc_error_to_string error)
;;

let test_raw_trace_read_permission_requires_a_token () =
  with_traces [] (fun config _trace_dir ->
    Auth.save_auth_config config.base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let worker = create_token_exn config.base_path ~agent_name:"worker" ~role:Masc_domain.Worker in
    let admin = create_token_exn config.base_path ~agent_name:"admin" ~role:Masc_domain.Admin in
    let authorize request =
      Server_auth.authorize_token_bound_permission_request
        ~base_path:config.base_path
        ~permission:Masc_domain.CanAdmin
        request
    in
    let anonymous = Httpun.Request.create `GET "/api/v1/keepers/test-keeper/raw-traces" in
    (match authorize anonymous with
     | Error error ->
       Alcotest.(check bool) "anonymous is unauthorized" true
         (Server_auth.http_status_of_auth_error error = `Unauthorized)
     | Ok actor -> Alcotest.failf "anonymous resolved actor %s" actor);
    (match authorize (bearer_request worker) with
     | Error error ->
       Alcotest.(check bool) "Worker is forbidden" true
         (Server_auth.http_status_of_auth_error error = `Forbidden)
     | Ok actor -> Alcotest.failf "Worker unexpectedly resolved actor %s" actor);
    Alcotest.(check (result string string)) "Admin can read"
      (Ok "admin")
      (authorize (bearer_request admin)
       |> Result.map_error Masc_domain.masc_error_to_string))
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
         (match List.map (fun (record : Reader.turn_record) -> record.parsed) records.records with
          | [ Ok _; Error _; Ok _ ] -> ()
          | _ -> Alcotest.fail "the torn line must occupy position 2"))
;;

let test_literal_raw_line_is_retained_before_decode () =
  let raw = {|{"seq":1, "record_type":"assistant_block", "text":"spacing stays"}|} in
  with_traces
    [ "turn-raw" ^ Support.raw_trace_file_extension, [ raw ] ]
    (fun config _dir ->
       match
         Reader.read_turn
           ~config
           ~keeper
           ~file:("turn-raw" ^ Support.raw_trace_file_extension)
           ~offset:0
           ~limit:10
       with
       | Error error -> Alcotest.failf "read failed: %s" (Reader.read_error_to_string error)
       | Ok { records = [ record ]; _ } ->
         Alcotest.(check string) "literal JSONL survives" raw record.raw
       | Ok records ->
         Alcotest.failf "expected one record, got %d" (List.length records.records))
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
        ; Alcotest.test_case "symlink traces are rejected" `Quick
            test_symlink_trace_is_rejected_for_listing_and_read
        ; Alcotest.test_case "raw trace read requires Admin token" `Quick
            test_raw_trace_read_permission_requires_a_token
        ] )
    ; ( "listing"
      , [ Alcotest.test_case "lists turns newest first" `Quick
            test_lists_turns_newest_first
        ; Alcotest.test_case "listing does not read past the prefix budget" `Quick
            test_listing_does_not_read_past_the_budget
        ; Alcotest.test_case "absent keeper directory is empty, not error" `Quick
            test_absent_keeper_directory_is_empty_not_error
        ; Alcotest.test_case "mixed session ids reject the listing" `Quick
            test_mixed_session_ids_reject_the_listing
        ; Alcotest.test_case "invalid trace identities reject the listing" `Quick
            test_missing_malformed_and_invalid_trace_ids_reject_the_listing
        ] )
    ; ( "reading"
      , [ Alcotest.test_case "missing turn is its own error" `Quick
            test_missing_turn_is_its_own_error
        ; Alcotest.test_case "unparseable line keeps its position" `Quick
            test_unparseable_line_keeps_its_position
        ; Alcotest.test_case "literal raw line survives decoding" `Quick
            test_literal_raw_line_is_retained_before_decode
        ; Alcotest.test_case "offset and limit window the file" `Quick
            test_offset_and_limit_window_the_file
        ] )
    ]
;;
