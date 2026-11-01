open Alcotest
module B = Masc_board_handlers.Board_initialization
module Offline = Board_posts_initialization_offline
module Lease = Server_startup_takeover

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let read path = In_channel.with_open_bin path In_channel.input_all
let write path bytes = Out_channel.with_open_bin path (fun out -> output_string out bytes)
let entries path = Sys.readdir path |> Array.to_list |> List.sort String.compare
let absent path = match Unix.lstat path with
  | _ -> false | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true
let masc base = Filename.concat base ".masc"
let posts base = Filename.concat (masc base) "board_posts.jsonl"
let guard base = Filename.concat (masc base) "board_posts.initialized.jsonl"

let with_workspace operation () =
  let root = Unix.realpath (Filename.temp_dir "offline-board-adapter-" "") in
  let base = Filename.concat root "workspace" and run = Filename.concat root "run" in
  Unix.mkdir base 0o700; Unix.mkdir run 0o700;
  let previous = Sys.getenv_opt "MASC_BASE_PATH_LEASE_DIR" in
  Unix.putenv "MASC_BASE_PATH_LEASE_DIR" run;
  Fun.protect ~finally:(fun () ->
    (match previous with Some value -> Unix.putenv "MASC_BASE_PATH_LEASE_DIR" value
     | None -> Unix.unsetenv "MASC_BASE_PATH_LEASE_DIR");
    remove_tree root)
    (fun () ->
      check string "test uses the real configured host lease directory" run
        (Host_config.host ()).base_path_lease_dir;
      operation ~root ~base ~run)

let intent base expected =
  let inspection = B.inspect ~base_path:base in
  check bool "actual typed decision" true (B.decision inspection = expected);
  B.finish_inspection inspection;
  match B.intent_sha256 inspection with
  | Some value -> value
  | None -> fail "actual actionable inspection returned no intent"

let check_exit expected response =
  check int "typed adapter exit projection" expected (Offline.exit_code response);
  Offline.finish response

let refusal_kind response =
  let open Yojson.Safe.Util in
  Offline.response_to_yojson response |> member "refusal" |> member "kind" |> to_string

let test_inspect ~root:_ ~base ~run =
  Unix.putenv "MASC_BASE_PATH_LEASE_DIR" (Filename.concat run "missing/nested");
  check_exit 0 (Offline.inspect ~base_path:base);
  check (list string) "inspection leaves .masc absent" [] (entries base);
  check (list string) "inspection never acquires or creates a host lease" [] (entries run)

let test_bootstrap ~root:_ ~base ~run:_ =
  let expected_intent_sha256 = intent base B.Bootstrap_required in
  check_exit 0 (Offline.bootstrap ~base_path:base ~expected_intent_sha256);
  check string "bootstrap publishes actual Present(empty) posts" "" (read (posts base));
  let generation = read (guard base) in
  check bool "actual initialized posts are observed Ready" true
    (B.decision (B.inspect ~base_path:base) = B.Ready_observed);
  check_exit 1 (Offline.bootstrap ~base_path:base ~expected_intent_sha256);
  check string "repeat does not remint the guard or claim a prior receipt" generation (read (guard base));
  List.iter (fun name -> check bool (name ^ " stays absent") true
      (absent (Filename.concat (masc base) name)))
    ["board_comments.jsonl"; "board_reactions.jsonl"; "board_sub_boards.jsonl"; "board_votes.jsonl"]

let producer_wire root =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Fun.protect ~finally:Fs_compat.clear_fs (fun () ->
      let store = Masc.Board.create_store ~workspace_masc_dir:(masc (Filename.concat root "producer")) () in
      (match Masc_board_handlers.Board_votes_json.load_persisted_posts store with
       | Ok 0 -> () | Ok _ | Error _ -> fail "actual producer did not load Missing");
      match Masc.Board.create_post store ~lookup:Masc_board_handlers.Recipient_lookup.none_declared
          ~author:"offline-producer" ~content:"retained raw source" ~post_kind:Masc.Board.Human_post
          ~ttl_hours:0 () with
      | Ok post -> Yojson.Safe.to_string (Masc.Board.post_to_yojson post)
      | Error failure -> fail (Masc.Board.Post_publication_failure.to_string failure)))

let test_adopt ~root ~base ~run:_ =
  let row = producer_wire root in
  Unix.mkdir (masc base) 0o700;
  let bytes = " \t\n" ^ row ^ "\r\n" ^ row ^ "\n" in
  write (posts base) bytes;
  (* Unrelated survivors must not become an adoption health requirement. *)
  write (Filename.concat (masc base) "board_comments.jsonl") "not a current row";
  Unix.symlink (Filename.concat root "absent-dependent-target")
    (Filename.concat (masc base) "board_votes.jsonl");
  let expected_intent_sha256 = intent base B.Adoption_required in
  let replaced = posts base ^ ".replacement" in
  write replaced bytes; Unix.rename replaced (posts base);
  check string "same-byte replacement retains logical content intent" expected_intent_sha256
    (intent base B.Adoption_required);
  check_exit 0 (Offline.adopt ~base_path:base ~expected_intent_sha256);
  check string "adoption preserves duplicates, blanks and CRLF exactly" bytes (read (posts base));
  check bool "guard and posts now observe Ready despite unrelated survivors" true
    (B.decision (B.inspect ~base_path:base) = B.Ready_observed);
  check string "unrelated malformed bytes are untouched" "not a current row"
    (read (Filename.concat (masc base) "board_comments.jsonl"))

let with_lease base operation =
  match Lease.acquire_base_path_lock ~run_dir:(Host_config.host ()).base_path_lease_dir base with
  | Lease.Base_path_acquired lease ->
    Fun.protect ~finally:(fun () -> Lease.release_base_path_lease lease) operation
  | Base_path_already_owned _ | Base_path_rejected _ -> fail "fixture could not acquire actual lease"

let test_same_process_owner ~root ~base ~run:_ =
  let expected_intent_sha256 = intent base B.Bootstrap_required in
  let alias = Filename.concat root "workspace-alias" in
  Unix.symlink base alias;
  with_lease base (fun () ->
    List.iter (fun base_path ->
      let response = Offline.bootstrap ~base_path ~expected_intent_sha256 in
      check_exit 1 response;
      check string "actual same-process owner refuses aliases" "workspace_in_use" (refusal_kind response);
      check string "owner identity is the actual typed this-process refusal" "this_process"
        Yojson.Safe.Util.(Offline.response_to_yojson response |> member "refusal" |> member "owner_kind" |> to_string)
    ) [base; alias];
    check bool "contended owner never publishes posts" true (absent (posts base));
    check bool "contended owner never publishes guard" true (absent (guard base)));
  check string "lease-created .masc does not stale content intent" expected_intent_sha256
    (intent alias B.Bootstrap_required);
  check_exit 0 (Offline.bootstrap ~base_path:alias ~expected_intent_sha256)

let test_invalid_intent ~root:_ ~base ~run =
  let response = Offline.bootstrap ~base_path:base ~expected_intent_sha256:"INVALID" in
  check_exit 1 response;
  check string "invalid digest has a typed input refusal" "invalid_intent" (refusal_kind response);
  check (list string) "invalid intent acquires no lease" [] (entries run);
  check (list string) "invalid intent creates no workspace metadata" [] (entries base)

let test_empty_base_path ~root:_ ~base:_ ~run =
  List.iter (fun response ->
    check_exit 1 response;
    check string "empty path does not silently select cwd" "empty_base_path" (refusal_kind response))
    [Offline.inspect ~base_path:"";
     Offline.bootstrap ~base_path:"" ~expected_intent_sha256:(String.make 64 '0');
     Offline.adopt ~base_path:"" ~expected_intent_sha256:(String.make 64 '0')];
  check (list string) "empty input creates no host lease" [] (entries run)

let test_parent_alias ~root ~base ~run =
  let external_dir = Filename.concat root "external" in
  Unix.mkdir external_dir 0o700; Unix.symlink external_dir (masc base);
  let before = Unix.lstat (masc base) in
  let response = Offline.bootstrap ~base_path:base ~expected_intent_sha256:(String.make 64 '0') in
  check_exit 1 response;
  check string "lexical parent alias refuses before lease" "parent_refused" (refusal_kind response);
  check int "alias inode remains" before.Unix.st_ino (Unix.lstat (masc base)).Unix.st_ino;
  check (list string) "external directory remains untouched" [] (entries external_dir);
  check (list string) "parent alias acquires no host lease" [] (entries run)

let test_changed_root ~root ~base ~run:_ =
  let expected_intent_sha256 = intent base B.Bootstrap_required in
  Unix.rename base (Filename.concat root "old-workspace"); Unix.mkdir base 0o700;
  check_exit 1 (Offline.bootstrap ~base_path:base ~expected_intent_sha256);
  check bool "new physical root cannot consume old intent" true (absent (posts base));
  check bool "new physical root gets no guard" true (absent (guard base))

let test_real_execution_context ~root:_ ~base ~run:_ =
  Eio_main.run (fun _ -> check_exit 0 (Offline.inspect ~base_path:base));
  let expected_intent_sha256 = intent base B.Bootstrap_required in
  let response = Domain.spawn (fun () -> Offline.bootstrap ~base_path:base ~expected_intent_sha256)
      |> Domain.join in
  check_exit 0 response;
  check string "raw Domain obtained actual empty posts without Eio effects" "" (read (posts base))

let () =
  let case name test = test_case name `Quick (with_workspace test) in
  run "board_posts_initialization_offline" ["actual configured ownership", [
    case "inspection never accesses the lease" test_inspect;
    case "bootstrap and repeated request preserve current guard" test_bootstrap;
    case "adopt real producer bytes without unrelated-family health" test_adopt;
    case "same-process and canonical aliases contend" test_same_process_owner;
    case "invalid intent refuses before metadata effects" test_invalid_intent;
    case "empty root never selects cwd" test_empty_base_path;
    case "lexical parent alias refuses before acquisition" test_parent_alias;
    case "changed physical root stales intent" test_changed_root;
    case "actual Eio and raw Domain contexts" test_real_execution_context ]]
