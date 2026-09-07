open Alcotest

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path
;;

let with_path path f =
  let prior = Sys.getenv_opt "PATH" in
  Unix.putenv "PATH" path;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some value -> Unix.putenv "PATH" value
      | None -> Unix.putenv "PATH" "")
    f
;;

let with_cwd path f =
  let prior = Sys.getcwd () in
  Sys.chdir path;
  Fun.protect ~finally:(fun () -> Sys.chdir prior) f
;;

let touch path =
  let oc = open_out path in
  close_out oc
;;

let test_executable_path_split_search_path () =
  check
    (list string)
    "preserves empty entries (explicit separator)"
    [ ""; "/opt/bin"; "/usr/bin" ]
    (Executable_path.split_search_path
       ~separator:';'
       ";/opt/bin;/usr/bin");
  (* Also exercise the default: build the input from the SSOT
     [search_path_separator] so this asserts the platform-default split (a
     regression setting the wrong default would fail here) while staying
     platform-independent. *)
  let sep = String.make 1 Executable_path.search_path_separator in
  check
    (list string)
    "preserves empty entries (default separator)"
    [ ""; "/opt/bin"; "/usr/bin" ]
    (Executable_path.split_search_path (sep ^ "/opt/bin" ^ sep ^ "/usr/bin"))
;;

let test_executable_path_lookup_requires_executable_file () =
  let dir = temp_dir "executable-path-bits-" in
  let executable = Filename.concat dir "masc-test-tool" in
  let non_executable = Filename.concat dir "masc-test-data" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove executable with Sys_error _ -> ());
      (try Sys.remove non_executable with Sys_error _ -> ());
      try Unix.rmdir dir with Unix.Unix_error _ -> ())
    (fun () ->
      touch executable;
      touch non_executable;
      Unix.chmod executable 0o700;
      Unix.chmod non_executable 0o600;
      let getenv = function
        | "PATH" -> Some dir
        | _ -> None
      in
      check
        bool
        "executable file found"
        true
        (Executable_path.command_available ~getenv "masc-test-tool");
      check
        bool
        "non-executable file rejected"
        false
        (Executable_path.command_available ~getenv "masc-test-data"))
;;

let test_executable_path_ignores_empty_path_entries () =
  let dir = temp_dir "executable-path-empty-" in
  let name = "masc-test-tool" in
  let executable = Filename.concat dir name in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove executable with Sys_error _ -> ());
      try Unix.rmdir dir with Unix.Unix_error _ -> ())
    (fun () ->
      touch executable;
      Unix.chmod executable 0o700;
      with_cwd dir (fun () ->
        let empty_path = function
          | "PATH" -> Some ""
          | _ -> None
        in
        let explicit_path = function
          | "PATH" ->
            Some (String.make 1 Executable_path.search_path_separator ^ dir)
          | _ -> None
        in
        check
          bool
          "empty PATH entry is not cwd"
          false
          (Executable_path.command_available ~getenv:empty_path name);
        check
          bool
          "non-empty PATH entry still works"
          true
          (Executable_path.command_available ~getenv:explicit_path name)))
;;

let check_ocamllsp_command_not_found ~path =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  with_path path (fun () ->
    match
      Lsp_process_manager.spawn
        ~sw
        ~servers:Lsp_process_manager.command_of_language
        ~lang_id:"ocaml"
        ~workspace_root:path
        (Eio.Stdenv.process_mgr env)
    with
    | Error (Lsp_process_manager.Command_not_found "ocamllsp") -> ()
    | Error err ->
      failf
        "expected Command_not_found ocamllsp, got %s"
        (Format.asprintf "%a" Lsp_process_manager.pp_spawn_error err)
    | Ok proc ->
      Lsp_process_manager.shutdown proc;
      fail "expected non-executable PATH entry to be rejected before spawn")
;;

let test_spawn_rejects_non_executable_path_entry () =
  let dir = temp_dir "lsp-path-nonexec-" in
  let cmd = Filename.concat dir "ocamllsp" in
  let oc = open_out cmd in
  close_out oc;
  Unix.chmod cmd 0o600;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove cmd with Sys_error _ -> ());
      try Unix.rmdir dir with Unix.Unix_error _ -> ())
    (fun () -> check_ocamllsp_command_not_found ~path:dir)
;;

let test_spawn_rejects_directory_path_entry () =
  let dir = temp_dir "lsp-path-dir-" in
  let cmd_dir = Filename.concat dir "ocamllsp" in
  Unix.mkdir cmd_dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      (try Unix.rmdir cmd_dir with Unix.Unix_error _ -> ());
      try Unix.rmdir dir with Unix.Unix_error _ -> ())
    (fun () -> check_ocamllsp_command_not_found ~path:dir)
;;

(* [shutdown] must close ALL THREE held pipe FDs (stdin_w, stdout_r, stderr_r),
   not just two. RFC-0261 / #21546: a missing [stderr_r] close leaks 1 FD per
   failed init, still climbing monotonically and tripping the FD admission gate.

   To prove a reader FD is *closed* (rather than merely hitting EOF because the
   killed child closed its write end), we keep the PARENT's write end of each
   reader pipe open. With a live writer the reader never reaches EOF, so it only
   becomes unreadable when [shutdown] closes it: if a close is missing the read
   blocks and the timeout fires the assertion. The extra write ends are released
   by the enclosing switch at end of test. *)
let test_shutdown_signals_child_and_closes_held_pipes () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let stdin_r, stdin_w = Eio.Process.pipe ~sw proc_mgr in
  let stdout_r, stdout_w = Eio.Process.pipe ~sw proc_mgr in
  let stderr_r, stderr_w = Eio.Process.pipe ~sw proc_mgr in
  let proc =
    Eio.Process.spawn
      ~sw
      proc_mgr
      ~stdin:stdin_r
      ~stdout:stdout_w
      ~stderr:stderr_w
      [ "/bin/cat" ]
  in
  Eio.Flow.close stdin_r;
  (* Intentionally keep [stdout_w] and [stderr_w] open so the reader FDs stay
     readable until [shutdown] closes them (see header comment). *)
  let lsp_proc =
    { Lsp_process_manager.lang_id = "test"
    ; proc
    ; stdin_w
    ; stdout_r
    ; stderr_r
    }
  in
  Lsp_process_manager.shutdown lsp_proc;
  (* Idempotent: a second teardown (e.g. evict after a failed init) must not raise. *)
  Lsp_process_manager.shutdown lsp_proc;
  let reader_closed what read_thunk =
    try
      Eio.Time.with_timeout_exn clock 0.1 read_thunk;
      false
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Eio.Time.Timeout -> fail (what ^ " did not close")
    | _ -> true
  in
  let write_failed =
    try
      Eio.Flow.copy_string "ignored" stdin_w;
      false
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> true
  in
  check bool "stdin writer closed" true write_failed;
  check
    bool
    "stdout reader closed"
    true
    (reader_closed "stdout reader" (fun () ->
       Eio.Flow.read_exact stdout_r (Cstruct.create 1)));
  check
    bool
    "stderr reader closed"
    true
    (reader_closed "stderr reader" (fun () ->
       Eio.Flow.read_exact stderr_r (Cstruct.create 1)));
  ignore (Eio.Time.with_timeout_exn clock 2.0 (fun () -> Eio.Process.await proc))
;;

(* The language table is one variant and several exhaustive functions; the
   list [all_languages] is the one thing the compiler cannot check, so these
   walk the list against the functions and the functions against the list. *)
let test_every_language_round_trips_its_wire_id () =
  List.iter
    (fun language ->
      let id = Lsp_process_manager.lang_id_of_language language in
      check bool (id ^ " comes back") true
        (Lsp_process_manager.language_of_lang_id id = Some language))
    Lsp_process_manager.all_languages;
  check bool "an id nobody speaks is None" true
    (Lsp_process_manager.language_of_lang_id "cobol" = None)
;;

let test_every_extension_maps_back_to_its_language () =
  List.iter
    (fun language ->
      let extensions = Lsp_process_manager.extensions_of_language language in
      check bool
        (Lsp_process_manager.lang_id_of_language language ^ " owns an extension")
        true (extensions <> []);
      List.iter
        (fun ext ->
          check bool (ext ^ " maps back") true
            (Lsp_process_manager.language_of_path ("dir/file" ^ ext) = Some language);
          check bool (ext ^ " upper-case maps back") true
            (Lsp_process_manager.language_of_path
               ("dir/FILE" ^ String.uppercase_ascii ext)
             = Some language))
        extensions)
    Lsp_process_manager.all_languages;
  check bool "an extension nobody owns is None" true
    (Lsp_process_manager.language_of_path "notes.cobol" = None);
  check string "shell is shellscript on the wire" "shellscript"
    (Lsp_process_manager.lang_of_path "deploy.sh");
  check string "no extension is unknown" "unknown" (Lsp_process_manager.lang_of_path "Makefile")
;;

let test_every_command_names_one_executable () =
  List.iter
    (fun language ->
      let id = Lsp_process_manager.lang_id_of_language language in
      let executable, argv = Lsp_process_manager.command_of_language language in
      check bool (id ^ " names an executable") true (executable <> "");
      check bool (id ^ " executable is one word") false (String.contains executable ' ');
      check (option string) (id ^ " argv starts with the executable") (Some executable)
        (List.nth_opt argv 0);
      check bool (id ^ " is reachable by wire id") true
        (Lsp_process_manager.command_for_lang id = Some (executable, argv)))
    Lsp_process_manager.all_languages
;;

let test_covered_extensions_are_the_table () =
  let covered = Lsp_process_manager.covered_extensions () in
  check bool "every language's extensions are covered" true
    (List.for_all
       (fun language ->
         List.for_all
           (fun ext -> List.mem ext covered)
           (Lsp_process_manager.extensions_of_language language))
       Lsp_process_manager.all_languages);
  check bool "no extension is listed twice" true
    (List.length covered = List.length (List.sort_uniq compare covered))
;;

(* The memo a keeper leaves is a comment in the file's own syntax, so every
   language that has one must spell a memo the reader reads back. Walked
   over the list, so a language added with a marker the reader lacks fails
   here rather than as a memo nobody sees. *)
let test_every_language_with_comments_writes_a_memo_it_reads_back () =
  let memo =
    { Ide_memo.author = "alpha"; kind = Agent_observation.Question; text = "why three" }
  in
  List.iter
    (fun language ->
      let id = Lsp_process_manager.lang_id_of_language language in
      match Lsp_process_manager.memo_markers_of_language language with
      | None ->
        check bool (id ^ " is the one language without comments") true
          (language = Lsp_process_manager.Json)
      | Some markers ->
        (match Ide_memo.of_comment (Ide_memo.to_line markers memo) with
         | Ide_memo.Memo read -> check bool (id ^ " reads its own memo back") true (read = memo)
         | Ide_memo.Malformed why -> Alcotest.failf "%s: malformed: %s" id why
         | Ide_memo.Not_a_memo -> Alcotest.failf "%s: the reader does not know its marker" id))
    Lsp_process_manager.all_languages;
  (match Lsp_process_manager.memo_line ~path:"notes/readme.md" memo with
   | Ok line ->
     check string "markdown spells it as an html comment"
       "<!-- masc(alpha) question: why three -->" line
   | Error refusal ->
     Alcotest.fail (Lsp_process_manager.memo_line_refusal_to_string refusal));
  (match Lsp_process_manager.memo_markers_of_path "init.lua" with
   | Ok (Ide_memo.Line "--") -> ()
   | Ok markers ->
     Alcotest.failf "lua: wrong markers: %s"
       (Ide_memo.to_line markers memo)
   | Error refusal ->
     Alcotest.fail (Lsp_process_manager.memo_line_refusal_to_string refusal));
  (match Lsp_process_manager.memo_line ~path:"data.json" memo with
   | Error (Lsp_process_manager.No_comment_syntax Lsp_process_manager.Json) -> ()
   | Error refusal ->
     Alcotest.failf "json: wrong refusal: %s"
       (Lsp_process_manager.memo_line_refusal_to_string refusal)
   | Ok line -> Alcotest.failf "json took a memo: %s" line);
  (match Lsp_process_manager.memo_line ~path:"notes.COBOL" memo with
   | Error (Lsp_process_manager.Extension_unknown ".cobol") -> ()
   | Error refusal ->
     Alcotest.failf "cobol: wrong refusal: %s"
       (Lsp_process_manager.memo_line_refusal_to_string refusal)
   | Ok line -> Alcotest.failf "cobol took a memo: %s" line)
;;

let () =
  run
    "lsp_process_manager"
    [ ( "executable-path"
      , [ test_case
            "splits PATH with SSOT separator"
            `Quick
            test_executable_path_split_search_path
        ; test_case
            "requires executable files"
            `Quick
            test_executable_path_lookup_requires_executable_file
        ; test_case
            "ignores empty PATH entries"
            `Quick
            test_executable_path_ignores_empty_path_entries
        ] )
    ; ( "path-resolution"
      , [ test_case
            "rejects non-executable PATH file before spawn"
            `Quick
            test_spawn_rejects_non_executable_path_entry
        ; test_case
            "rejects PATH directory before spawn"
            `Quick
            test_spawn_rejects_directory_path_entry
        ] )
    ; ( "shutdown"
      , [ test_case
            "signals child and closes held pipes"
            `Quick
            test_shutdown_signals_child_and_closes_held_pipes
        ] )
    ; ( "languages"
      , [ test_case "every listed language round-trips its wire id" `Quick
            test_every_language_round_trips_its_wire_id
        ; test_case "every extension maps back to its language" `Quick
            test_every_extension_maps_back_to_its_language
        ; test_case "every command names one executable as argv head" `Quick
            test_every_command_names_one_executable
        ; test_case "the covered extensions are the table read the other way" `Quick
            test_covered_extensions_are_the_table
        ; test_case "every language with comments writes a memo it reads back" `Quick
            test_every_language_with_comments_writes_a_memo_it_reads_back
        ] )
    ]
;;
