(** RFC a-language-server-the-keeper-can-ask: the Keeper's surface.

    [Lsp_workspace_pool] and [Lsp_questions] are tested on their own. What is
    asserted here is what a Keeper sees: which questions are offered, and that
    every refusal names the next move rather than only that something failed.

    None of these reach a language server. Each is refused at the tool's own
    boundary, which is the point -- a call that cannot be answered should not
    start a server to find that out. *)

open Masc

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_file "masc-code-query" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let dir = Fs_compat.realpath_lenient dir in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Filename.quote_command "rm" [ "-rf"; dir ])))
    (fun () ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:(Some "keeper-probe-agent"));
      f env config)
;;

let with_env_workspace = with_workspace
let with_workspace f = with_env_workspace (fun _env config -> f config)

let meta () : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "probe"
        ; "agent_name", `String "keeper-probe-agent"
        ; "trace_id", `String "trace-probe"
        ; "autoboot_enabled", `Bool false
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)
;;

let call ~config args =
  match
    Keeper_tool_code_query.dispatch
      ~config
      ~meta:(meta ())
      ~name:"keeper_code_query"
      ~args
  with
  | Some result -> result
  | None -> Alcotest.fail "keeper_code_query must be dispatched here"
;;

let refusal_message ~config args =
  let result = call ~config args in
  match Tool_result.failure_class result with
  | Some _ -> Tool_result.message result
  | None ->
    Alcotest.failf
      "expected a refusal, got: %s"
      (Yojson.Safe.to_string (Tool_result.data result))
;;

let mentions ~needle message =
  let needle_len = String.length needle in
  let rec scan from =
    if from + needle_len > String.length message
    then false
    else if String.equal (String.sub message from needle_len) needle
    then true
    else scan (from + 1)
  in
  scan 0
;;

let check_mentions what ~needle message =
  Alcotest.(check bool)
    (Printf.sprintf "%s names %S -- got: %s" what needle message)
    true
    (mentions ~needle message)
;;

let args ?(question = "hover") ?(line = 1) ?(symbol = "x") ?occurrence path =
  `Assoc
    ([ "question", `String question
     ; "path", `String path
     ; "line", `Int line
     ; "symbol", `String symbol
     ]
     @
     match occurrence with
     | Some n -> [ "occurrence", `Int n ]
     | None -> [])
;;

(* Inside the keeper's own sandbox root, which is not the workspace base path:
   a file written beside .masc is refused as outside, and that refusal is what
   the sandbox test above asserts. *)
let write ~config rel contents =
  let root = Keeper_sandbox.keeper_visible_root_abs_of_meta ~config (meta ()) in
  let path = Filename.concat root rel in
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc contents);
  path
;;

(* --- which questions are offered ---------------------------------------- *)

let test_a_keeper_is_offered_the_tool () =
  (* The tool was built, tested, and reachable only if it is registered. Three
     things in an earlier session were green the whole way and did nothing,
     which is why this is an assertion rather than a one-time check. *)
  let module TD = Masc.Keeper_tool_descriptor in
  let offered = List.map (fun d -> d.TD.internal_name) (TD.model_visible_descriptors ()) in
  Alcotest.(check bool)
    "a keeper is offered keeper_code_query"
    true
    (List.exists (String.equal "keeper_code_query") offered)
;;

let test_the_definition_offers_two_questions () =
  (* references answers same-file only on this repository (#30504). The enum
     is where a Keeper learns which questions exist, so it is where the third
     one is absent. *)
  let schema = Tool_schemas_code_query.schema in
  let json = Yojson.Safe.to_string schema.Masc_domain.input_schema in
  check_mentions "the schema" ~needle:"definition" json;
  check_mentions "the schema" ~needle:"hover" json;
  Alcotest.(check bool)
    ("references must not be offered -- got: " ^ json)
    false
    (mentions ~needle:"\"references\"" json)
;;

let test_references_is_refused_by_name () =
  with_workspace (fun config ->
    let path = write ~config "a.ml" "let value = 1\n" in
    let message = refusal_message ~config (args ~question:"references" ~symbol:"value" path) in
    check_mentions "the refusal" ~needle:"references" message;
    (* Names what to use instead, rather than only that it declined. *)
    check_mentions "the refusal" ~needle:"Grep" message)
;;

(* --- the sandbox bounds the question ------------------------------------ *)

let test_a_path_outside_the_workspace_is_refused () =
  with_workspace (fun config ->
    let outside = "/etc/hosts" in
    let message = refusal_message ~config (args ~symbol:"localhost" outside) in
    check_mentions "the refusal" ~needle:outside message)
;;

(* --- positions are 1-based, in and out ---------------------------------- *)

let test_line_zero_names_the_counting () =
  with_workspace (fun config ->
    let path = write ~config "a.ml" "let value = 1\n" in
    let message = refusal_message ~config (args ~line:0 ~symbol:"value" path) in
    check_mentions "the refusal" ~needle:"counted from 1" message)
;;

let test_a_symbol_not_on_the_line_shows_the_line () =
  with_workspace (fun config ->
    let path = write ~config "a.ml" "let value = 1\nlet other = 2\n" in
    let message = refusal_message ~config (args ~line:2 ~symbol:"value" path) in
    (* Showing the line is what lets the caller see it was one off. *)
    check_mentions "the refusal" ~needle:"let other = 2" message)
;;

let test_a_line_past_the_end_says_how_many_there_are () =
  with_workspace (fun config ->
    let path = write ~config "a.ml" "let value = 1\n" in
    let message = refusal_message ~config (args ~line:9 ~symbol:"value" path) in
    check_mentions "the refusal" ~needle:"line 9" message)
;;

let test_occurrence_beyond_the_count_says_the_count () =
  with_workspace (fun config ->
    let path = write ~config "a.ml" "let value = value + 1\n" in
    let message =
      refusal_message ~config (args ~line:1 ~symbol:"value" ~occurrence:5 path)
    in
    check_mentions "the refusal" ~needle:"2 time(s)" message;
    check_mentions "the refusal" ~needle:"occurrence 5" message)
;;

let test_an_unmapped_extension_is_refused_by_extension () =
  with_workspace (fun config ->
    let path = write ~config "notes.txt" "value\n" in
    let message = refusal_message ~config (args ~symbol:"value" path) in
    check_mentions "the refusal" ~needle:".txt" message)
;;

(* --- an answer from a real language server ------------------------------ *)

let ocamllsp_present () = Executable_path.path_has_executable "ocamllsp"

(* Everything above is refused before a server is reached, which is the point
   of those cases and the hole in them: none proves the chain runs. This one
   starts an ocamllsp, opens a document, asks, reads the answer back, and
   renders it -- on a two-line file whose answer needs no build, so it does not
   depend on the tree being compiled. *)
let test_definition_answers_from_a_real_server () =
  with_env_workspace (fun env config ->
    Eio_context.set_env env;
    let _ = write ~config "dune-project" "(lang dune 3.22)\n" in
    let path = write ~config "sample.ml" "let answer = 42\nlet doubled = answer * 2\n" in
    Lsp_turn_pool.with_turn_pool (fun () ->
      let result = call ~config (args ~question:"definition" ~line:2 ~symbol:"answer" path) in
      (match Tool_result.failure_class result with
       | Some _ -> Alcotest.failf "expected an answer, got: %s" (Tool_result.message result)
       | None -> ());
      match Yojson.Safe.Util.member "locations" (Tool_result.data result) with
      | `List [ `Assoc fields ] ->
        (* Reported the way Grep reports: the definition is on line 1, not 0. *)
        Alcotest.(check (option int))
          "the definition is on line 1"
          (Some 1)
          (match List.assoc_opt "line" fields with
           | Some (`Int line) -> Some line
           | Some _ | None -> None);
        Alcotest.(check (option bool))
          "and it is inside the workspace"
          (Some true)
          (match List.assoc_opt "in_workspace" fields with
           | Some (`Bool inside) -> Some inside
           | Some _ | None -> None);
        Alcotest.(check (option string))
          "named relative to the workspace root"
          (Some "sample.ml")
          (match List.assoc_opt "path" fields with
           | Some (`String path) -> Some path
           | Some _ | None -> None)
      | other ->
        Alcotest.failf "expected one location, got: %s" (Yojson.Safe.to_string other)))
;;

let live_server_cases =
  if ocamllsp_present ()
  then
    [ Alcotest.test_case
        "definition answers from a real ocamllsp"
        `Slow
        test_definition_answers_from_a_real_server
    ]
  else (
    print_endline
      "[keeper_tool_code_query] ocamllsp is not on PATH - skipping the case that needs one";
    [])
;;

let () =
  Alcotest.run
    "keeper_tool_code_query"
    [ ( "offered"
      , [ Alcotest.test_case "the tool is registered" `Quick test_a_keeper_is_offered_the_tool
        ; Alcotest.test_case
            "two questions, not three"
            `Quick
            test_the_definition_offers_two_questions
        ; Alcotest.test_case
            "references is refused by name"
            `Quick
            test_references_is_refused_by_name
        ] )
    ; ( "sandbox"
      , [ Alcotest.test_case
            "a path outside the workspace is refused"
            `Quick
            test_a_path_outside_the_workspace_is_refused
        ] )
    ; ( "positions"
      , [ Alcotest.test_case "line 0 names the counting" `Quick test_line_zero_names_the_counting
        ; Alcotest.test_case
            "a symbol not on the line shows the line"
            `Quick
            test_a_symbol_not_on_the_line_shows_the_line
        ; Alcotest.test_case
            "a line past the end says so"
            `Quick
            test_a_line_past_the_end_says_how_many_there_are
        ; Alcotest.test_case
            "occurrence beyond the count says the count"
            `Quick
            test_occurrence_beyond_the_count_says_the_count
        ; Alcotest.test_case
            "an unmapped extension is refused"
            `Quick
            test_an_unmapped_extension_is_refused_by_extension
        ] )
    ; "live server", live_server_cases
    ]
;;
