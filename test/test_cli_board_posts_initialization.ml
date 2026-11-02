open Alcotest
module C = Masc_cli_board_posts_initialization
module B = Masc_board_handlers.Board_initialization

let digest = String.make 64 'a'
let parse ?(base_path = "/selected-workspace") arguments =
  let sink = Format.make_formatter (fun _ _ _ -> ()) (fun () -> ()) in
  let command = C.cmd ~base_path:(Cmdliner.Term.const base_path) ~run:Fun.id in
  Cmdliner.Cmd.eval_value ~catch:false ~help:sink ~err:sink ~env:(fun _ -> None)
    ~argv:(Array.of_list ("board-posts" :: arguments)) command

let test_parser () =
  List.iter (fun (arguments, expected) ->
    match parse arguments with
    | Ok (`Ok request) ->
      check string "existing base-path term is routed unchanged" "/selected-workspace" request.C.base_path;
      check bool "actual typed action" true (request.action = expected)
    | _ -> fail "actual Cmdliner leaf rejected a valid request")
    [ ["inspect"], C.Inspect;
      ["bootstrap"; "--expected-intent-sha256"; digest], C.Bootstrap { expected_intent_sha256 = digest };
      ["adopt"; "--expected-intent-sha256"; digest], C.Adopt { expected_intent_sha256 = digest } ]

let test_bad_flags () =
  List.iter (fun arguments ->
    match parse arguments with Error _ -> () | Ok _ -> fail "invalid flags reached a request")
    [ ["bootstrap"]; ["adopt"];
      ["bootstrap"; "--expected-intent-sha256"; "short"];
      ["adopt"; "--expected-intent-sha256"; String.make 64 'A'];
      ["inspect"; "--expected-intent-sha256"; digest];
      ["bootstrap"; "--expected-layout-sha256"; digest];
      ["adopt"; "--posts-source-sha256"; digest];
      ["adopt"; "--force"] ];
  match parse ["--help=plain"] with Ok `Help -> () | _ -> fail "help attempted command execution"

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let read path = In_channel.with_open_bin path In_channel.input_all
let entries path = Sys.readdir path |> Array.to_list |> List.sort String.compare

let with_workspace operation () =
  let root = Unix.realpath (Filename.temp_dir "offline-board-cli-" "") in
  let base = Filename.concat root "workspace" and lease_root = Filename.concat root "leases" in
  Unix.mkdir base 0o700; Unix.mkdir lease_root 0o700;
  let previous = Sys.getenv_opt "MASC_BASE_PATH_LEASE_DIR" in
  Unix.putenv "MASC_BASE_PATH_LEASE_DIR" lease_root;
  Fun.protect ~finally:(fun () ->
    (match previous with Some value -> Unix.putenv "MASC_BASE_PATH_LEASE_DIR" value
     | None -> Unix.unsetenv "MASC_BASE_PATH_LEASE_DIR"); remove_tree root)
    (fun () -> operation ~root ~base ~lease_root)

let execute root request =
  let output = Filename.concat root "result.json" in
  let code = Out_channel.with_open_bin output (fun out -> C.run ~out request) in
  code, Yojson.Safe.from_string (read output)

let request base arguments =
  match parse ~base_path:base arguments with
  | Ok (`Ok request) -> request
  | _ -> fail "real filesystem command did not pass its actual parser"

let test_real_cli ~root ~base ~lease_root =
  let code, json = execute root (request base ["inspect"]) in
  check int "readonly CLI success" 0 code;
  check bool "actual structured readonly result" true
    Yojson.Safe.Util.(json |> member "read_only" |> to_bool);
  check (list string) "real inspect leaves workspace untouched" [] (entries base);
  check (list string) "real inspect leaves configured leases untouched" [] (entries lease_root);
  let expected_intent_sha256 = match B.intent_sha256 (B.inspect ~base_path:base) with
    | Some value -> value | None -> fail "real bootstrap inspection produced no intent" in
  let code, json = execute root (request base ["bootstrap"; "--expected-intent-sha256"; expected_intent_sha256]) in
  check int "actual CLI bootstrap completed" 0 code;
  check string "actual command response records its operation" "bootstrap"
    Yojson.Safe.Util.(json |> member "operation" |> to_string);
  check bool "CLI does not claim live guard enforcement" false
    Yojson.Safe.Util.(json |> member "live_posts_guard_enforced" |> to_bool);
  check string "actual CLI created empty persisted posts" ""
    (read (Filename.concat base ".masc/board_posts.jsonl"));
  let code, _ = execute root (request base ["adopt"; "--expected-intent-sha256"; expected_intent_sha256]) in
  check int "stale/wrong-action intent is an actual refusal" 1 code

let test_real_adopt ~root ~base ~lease_root:_ =
  Unix.mkdir (Filename.concat base ".masc") 0o700;
  let path = Filename.concat base ".masc/board_posts.jsonl" in
  let bytes = "\n \t\n" in
  Out_channel.with_open_bin path (fun out -> output_string out bytes);
  let observed = B.inspect ~base_path:base in
  check bool "actual existing source requires adoption" true
    (B.decision observed = B.Adoption_required);
  let expected_intent_sha256 = match B.intent_sha256 observed with
    | Some value -> value | None -> fail "actual adoption intent missing" in
  let code, json = execute root (request base ["adopt"; "--expected-intent-sha256"; expected_intent_sha256]) in
  check int "parsed real CLI adoption completed" 0 code;
  check string "real adoption command was selected" "adopt"
    Yojson.Safe.Util.(json |> member "operation" |> to_string);
  check string "real CLI adoption preserves raw blank rows" bytes (read path);
  check bool "CLI adoption published actual Ready data" true
    (B.decision (B.inspect ~base_path:base) = B.Ready_observed)

let test_output_failure ~root ~base ~lease_root:_ =
  let expected_intent_sha256 = match B.intent_sha256 (B.inspect ~base_path:base) with
    | Some value -> value | None -> fail "actual bootstrap intent missing" in
  let output = open_out_bin (Filename.concat root "closed-output") in
  close_out output;
  (match C.run ~out:output (request base ["bootstrap"; "--expected-intent-sha256"; expected_intent_sha256]) with
   | _ -> fail "closed output channel was accepted"
   | exception Sys_error _ -> ());
  check bool "reporting failure does not erase actual completed writes" true
    (B.decision (B.inspect ~base_path:base) = B.Ready_observed);
  check string "completed payload remains on disk" ""
    (read (Filename.concat base ".masc/board_posts.jsonl"))

let () =
  run "cli_board_posts_initialization" [
    "actual Cmdliner", [test_case "typed request routing" `Quick test_parser;
      test_case "required sole intent flags and help" `Quick test_bad_flags];
    "actual offline CLI", [test_case "inspect bootstrap and action refusal" `Quick (with_workspace test_real_cli);
      test_case "parsed adoption preserves real existing bytes" `Quick (with_workspace test_real_adopt);
      test_case "output failure preserves actual completion" `Quick (with_workspace test_output_failure)] ]
