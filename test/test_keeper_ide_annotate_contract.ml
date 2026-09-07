(* The keeper's line memo tool. A memo is a comment in the file's own
   syntax, inserted above the line the keeper names, through the write path
   Edit uses. What it must do: spell the memo the reader reads back, keep
   the line's indentation, and refuse with a reason rather than guess. *)

module Workspace = Masc.Workspace
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_tool_execution = Masc.Keeper_tool_execution
module Keeper_file_change_evidence = Masc.Keeper_file_change_evidence
module Keeper_registry = Masc.Keeper_registry
module Json = Yojson.Safe.Util

let () = Masc.Prompt_defaults.init ()

let temp_dir () =
  let d = Filename.temp_file "keeper_ide_annotate_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d
;;

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
      Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with
  | _ -> ()
;;

let rec ensure_dir path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    let p = Filename.dirname path in
    if p <> path then ensure_dir p;
    Unix.mkdir path 0o755)
;;

let make_meta name =
  let json = `Assoc [ "name", `String name; "always_allow", `Bool true ] in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> { m with Masc.Keeper_meta_contract.sandbox_profile = Keeper_types_profile_sandbox.Docker }
  | Error e -> Alcotest.fail e
;;

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let fs = Eio.Stdenv.fs env in
  Fs_compat.set_fs fs;
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ~fs ~sw ()
;;

let setup f =
  with_eio_fs @@ fun ~fs ~sw () ->
  let base = temp_dir () in
  let config = Workspace.default_config base in
  ensure_dir (Workspace.masc_root_dir config);
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.For_testing.clear ();
  let meta = make_meta "tester" in
  let playground = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir playground;
  ignore (Keeper_registry.For_testing.register ~base_path:base meta.name meta);
  Masc_test_deps.with_publication_recovery_registry
    ~sw
    ~fs
    ~registry_root:(Workspace.masc_root_dir config)
  @@ fun registry ->
  let publication_recovery =
    { Masc.Keeper_publication_recovery_availability.provider =
        Masc_test_deps.publication_recovery_provider registry
    ; keeper_name = meta.name
    }
  in
  f ~config ~meta ~playground ~publication_recovery
;;

let annotate ~config ~meta ~publication_recovery args =
  Masc.Keeper_tool_ide_runtime.handle_ide_annotate_with_outcome
    ~turn_sandbox_factory:None
    ~config
    ~meta
    ~publication_recovery
    ~args
    ()
;;

let raw (execution : Keeper_tool_execution.t) = execution.raw_output
let json raw = Yojson.Safe.from_string raw

let ok raw =
  json raw |> Json.member "ok" |> Json.to_bool_option |> Option.value ~default:false
;;

let error_text raw =
  json raw |> Json.member "error" |> Json.to_string_option |> Option.value ~default:""
;;

let args ?kind ~path ~line text =
  `Assoc
    ([ "file_path", `String path; "line", `Int line; "text", `String text ]
     @
     match kind with
     | None -> []
     | Some word -> [ "kind", `String word ])
;;

let test_a_memo_lands_above_the_line_in_the_files_syntax () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let a = 1\nlet b = 2\n";
  let execution =
    annotate ~config ~meta ~publication_recovery
      (args ~kind:"question" ~path ~line:2 "why two")
  in
  let out = raw execution in
  Alcotest.(check bool) ("ok: " ^ out) true (ok out);
  Alcotest.(check string) "the comment sits above line 2, in ocaml's syntax"
    "let a = 1\n(* masc(tester) question: why two *)\nlet b = 2\n"
    (Fs_compat.load_file path);
  Alcotest.(check (option string)) "the payload shows the line as written"
    (Some "(* masc(tester) question: why two *)")
    (json out |> Json.member "inserted" |> Json.to_string_option);
  match execution.file_change_evidence with
  | Some
      (Keeper_file_change_evidence.Edited
        { occurrence_count = 1; occurrences = Some [ occurrence ] }) ->
    let (range : Keeper_file_change_evidence.line_range) =
      occurrence.Keeper_file_change_evidence.old_range
    in
    Alcotest.(check int) "the evidence names the line it went above" 2 range.start_line
  | Some _ | None -> Alcotest.fail "expected one recorded edit occurrence"
;;

let test_python_takes_the_hash_and_the_indentation () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "tool.py" in
  Fs_compat.save_file path "def f():\n    return 1\n";
  let out = raw (annotate ~config ~meta ~publication_recovery (args ~path ~line:2 "keep")) in
  Alcotest.(check bool) ("ok: " ^ out) true (ok out);
  Alcotest.(check string) "a hash comment, indented like the line below it"
    "def f():\n    # masc(tester): keep\n    return 1\n"
    (Fs_compat.load_file path)
;;

let test_the_reader_reads_the_memo_back () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "tool.py" in
  Fs_compat.save_file path "def f():\n    return 1\n";
  let out =
    raw (annotate ~config ~meta ~publication_recovery (args ~kind:"bookmark" ~path ~line:1 "start here"))
  in
  Alcotest.(check bool) ("ok: " ^ out) true (ok out);
  match String.split_on_char '\n' (Fs_compat.load_file path) with
  | first :: _ ->
    (match Ide_memo.of_comment first with
     | Ide_memo.Memo memo ->
       Alcotest.(check string) "author is the keeper" "tester" memo.Ide_memo.author;
       Alcotest.(check bool) "kind" true (memo.Ide_memo.kind = Agent_observation.Bookmark);
       Alcotest.(check string) "text" "start here" memo.Ide_memo.text
     | Ide_memo.Malformed why -> Alcotest.failf "the written memo is malformed: %s" why
     | Ide_memo.Not_a_memo -> Alcotest.failf "the written line is not a memo: %s" first)
  | [] -> Alcotest.fail "the file is empty"
;;

let refused ~config ~meta ~publication_recovery ~reason args =
  let out = raw (annotate ~config ~meta ~publication_recovery args) in
  Alcotest.(check bool) ("refused: " ^ out) false (ok out);
  Alcotest.(check bool)
    (Printf.sprintf "names the reason %S in %S" reason (error_text out))
    true
    (String_util.contains_substring (error_text out) reason)
;;

let test_a_file_nobody_owns_is_refused () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "notes.cobol" in
  Fs_compat.save_file path "IDENTIFICATION DIVISION.\n";
  refused ~config ~meta ~publication_recovery ~reason:"no language here owns"
    (args ~path ~line:1 "x");
  Alcotest.(check string) "untouched" "IDENTIFICATION DIVISION.\n" (Fs_compat.load_file path)
;;

let test_json_has_no_comment_syntax () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "data.json" in
  Fs_compat.save_file path "{}\n";
  refused ~config ~meta ~publication_recovery ~reason:"no comment syntax" (args ~path ~line:1 "x");
  Alcotest.(check string) "untouched" "{}\n" (Fs_compat.load_file path)
;;

let test_a_kind_nobody_knows_is_refused () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let a = 1\n";
  refused ~config ~meta ~publication_recovery ~reason:"kind must be one of"
    (args ~kind:"verdict" ~path ~line:1 "x")
;;

let test_a_line_past_the_end_is_refused () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let a = 1\n";
  refused ~config ~meta ~publication_recovery ~reason:"line 5 does not exist"
    (args ~path ~line:5 "x");
  Alcotest.(check string) "untouched" "let a = 1\n" (Fs_compat.load_file path)
;;

let test_empty_text_is_refused () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let a = 1\n";
  refused ~config ~meta ~publication_recovery ~reason:"no text" (args ~path ~line:1 "   ")
;;

let () =
  Alcotest.run
    "keeper_ide_annotate"
    [ ( "writes"
      , [ Alcotest.test_case "a memo lands above the line in the file's syntax" `Quick
            test_a_memo_lands_above_the_line_in_the_files_syntax
        ; Alcotest.test_case "python takes the hash and the indentation" `Quick
            test_python_takes_the_hash_and_the_indentation
        ; Alcotest.test_case "the reader reads the memo back" `Quick
            test_the_reader_reads_the_memo_back
        ] )
    ; ( "refusals"
      , [ Alcotest.test_case "a file nobody owns" `Quick test_a_file_nobody_owns_is_refused
        ; Alcotest.test_case "json has no comment syntax" `Quick test_json_has_no_comment_syntax
        ; Alcotest.test_case "a kind nobody knows" `Quick test_a_kind_nobody_knows_is_refused
        ; Alcotest.test_case "a line past the end" `Quick test_a_line_past_the_end_is_refused
        ; Alcotest.test_case "empty text" `Quick test_empty_text_is_refused
        ] )
    ]
;;
