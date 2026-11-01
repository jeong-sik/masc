(** Real offline observations and interrupted publication prefixes. No test
    invents a stable snapshot, cursor, guard receipt or Board admission. *)
open Masc

module I = Masc_board_handlers.Board_initialization
module Paths = Masc_board_handlers.Board_paths
module Rows = Masc_board_handlers.Board_votes_json

let check_bool = Alcotest.(check bool)
let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)
let check_optional_string = Alcotest.(check (option string))
let check_strings = Alcotest.(check (list string))
let check_identity = Alcotest.(check (pair int int))

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Unix.chmod path 0o700;
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_fixture test () =
  let base = Unix.realpath (Filename.temp_dir "board-initialization-" "") in
  Fs_compat.clear_fs ();
  Fun.protect
    ~finally:(fun () -> Fs_compat.clear_fs (); remove_tree base)
    (fun () -> test base)

let in_eio test =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Fun.protect ~finally:Fs_compat.clear_fs test)

let workspace base = Common.masc_dir_from_base_path ~base_path:base
let posts_path base = Paths.posts_file ~workspace_masc_dir:(workspace base)
let guard_path base = Paths.posts_initialization_guard_file ~workspace_masc_dir:(workspace base)
let read_bytes path = In_channel.with_open_bin path In_channel.input_all
let write_bytes path bytes =
  Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let entries path = Sys.readdir path |> Array.to_list |> List.sort String.compare
let absent path =
  match Unix.lstat path with
  | _ -> false
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true
let prepare base bytes =
  Unix.mkdir (workspace base) 0o750;
  write_bytes (posts_path base) bytes

let state path =
  let s = Unix.lstat path in
  s.Unix.st_dev, s.Unix.st_ino, s.Unix.st_nlink, s.Unix.st_perm, read_bytes path

let json_member name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> value
     | None -> Alcotest.fail ("missing structured field " ^ name))
  | _ -> Alcotest.fail ("non-object containing " ^ name)

let json_string = function
  | `String value -> value
  | _ -> Alcotest.fail "expected a structured string"

let check_decision label expected inspection =
  check_bool label true (I.decision inspection = expected)

let inspect base =
  let observed = I.inspect ~base_path:base in
  I.finish_inspection observed;
  observed

let token inspection =
  match I.intent_sha256 inspection with
  | Some value -> value
  | None -> Alcotest.fail "actionable observation has no intent token"

let check_refused inspection =
  check_decision "typed refusal" I.Refused inspection;
  check_optional_string "refusal grants no mutation intent" None
    (I.intent_sha256 inspection)

let check_completed outcome =
  check_bool "both current durable receipts complete" true
    (I.completion outcome = I.Completed);
  check_bool "pure finish agrees" true (I.finish_outcome outcome = I.Completed)

let check_incomplete outcome =
  check_bool "invocation is not complete" true
    (I.completion outcome = I.Not_completed)

let check_effect outcome field expected =
  let actual = I.outcome_to_yojson outcome |> json_member field
    |> json_member "effect" |> json_string in
  check_string (field ^ " actual effect prefix") expected actual

let check_diagnostic outcome field =
  match I.outcome_to_yojson outcome |> json_member field |> json_member "diagnostics" with
  | `List (_ :: _) -> ()
  | `List [] -> Alcotest.fail "actual transaction diagnostic was discarded"
  | _ -> Alcotest.fail "transaction diagnostics are not an array"

let check_dependents_not_examined inspection =
  let actual = I.inspection_to_yojson inspection |> json_member "dependents"
    |> json_member "state" |> json_string in
  check_string "unrelated families were not inspected" "not_examined" actual

let test_absent_root_and_noncreating_inspect base =
  let missing_parent = Filename.concat base "absent" in
  let selected = Filename.concat missing_parent "nested" in
  check_refused (inspect selected);
  check_bool "missing BasePath remains absent" true (absent missing_parent);
  let before = entries base in
  let observation = inspect base in
  check_decision "existing unused BasePath needs explicit bootstrap" I.Bootstrap_required observation;
  ignore (token observation);
  in_eio (fun () ->
    check_decision "fiber inspection agrees" I.Bootstrap_required (inspect base));
  check_bool "inspection creates no .masc" true (absent (workspace base));
  check_strings "no observation metadata was created" before (entries base)

let test_aliases_and_missing_directory_token base =
  let root = Filename.concat base "root" in
  Unix.mkdir root 0o750;
  let alias = Filename.concat base "alias" in
  Unix.symlink root alias;
  let original = token (inspect root) in
  check_string "physical root alias shares logical intent" original (token (inspect alias));
  Unix.mkdir (workspace root) 0o750;
  check_string "creating only the parent does not stale content intent"
    original (token (inspect root));
  check_strings "inspection creates no locks" [] (entries (workspace root))

let test_workspace_alias dangling base =
  let root = Filename.concat base "root" in
  Unix.mkdir root 0o750;
  let target = Filename.concat base "outside" in
  if not dangling then Unix.mkdir target 0o750;
  Unix.symlink target (workspace root);
  let before = Unix.lstat (workspace root) in
  check_refused (inspect root);
  let after = Unix.lstat (workspace root) in
  check_identity ".masc link binding is preserved"
    (before.Unix.st_dev, before.Unix.st_ino) (after.Unix.st_dev, after.Unix.st_ino);
  check_string ".masc alias target is preserved" target (Unix.readlink (workspace root));
  if dangling then
    check_bool "external missing target stays absent" true (absent target)
  else check_strings "external directory stays empty" [] (entries target)

let test_missing_and_present_empty base =
  let missing = inspect base in
  check_decision "Missing is bootstrap intent" I.Bootstrap_required missing;
  check_optional_string "Missing has no raw content digest" None
    (I.posts_source_sha256 missing);
  prepare base "";
  let empty = inspect base in
  check_decision "Present(empty) requires adoption" I.Adoption_required empty;
  check_optional_string "empty file has actual SHA256"
    (Some (Agent_core_sha256.(to_hex (digest_string "")))) (I.posts_source_sha256 empty);
  check_bool "action domains differ" false (token missing = token empty);
  check_dependents_not_examined empty;
  check_strings "empty-file inspection creates no sidecars"
    [Filename.basename (posts_path base)] (entries (workspace base))

let actual_post_row base =
  let seed = Filename.concat base "producer" in
  in_eio (fun () ->
    let store = Board.create_store ~workspace_masc_dir:(workspace seed) () in
    (match Rows.load_persisted_posts store with
     | Ok 0 -> ()
     | Ok _ | Error _ -> Alcotest.fail "fresh producer did not load actual Missing");
    match Board.create_post store ~lookup:Recipient_lookup.none_declared
      ~author:"initialization-author" ~content:"actual producer bytes"
      ~title:"initialization title" ~body:"actual producer bytes"
      ~post_kind:Board.Human_post ~ttl_hours:0 () with
    | Ok post -> Board.post_to_yojson post
    | Error failure -> Alcotest.fail (Board.Post_publication_failure.to_string failure))

let set_field row key value = match row with
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> Alcotest.fail "actual producer returned a non-object"

let test_raw_content_adoption base =
  let row = actual_post_row base in
  let transferred = set_field row "author" (`String "transferred-owner") in
  let transferred = set_field transferred "origin" (`Assoc [
    "source", `String "fusion"; "fusion_run_id", `String "actual-initialization";
    "fusion_producer", `String "  original-producer  " ]) in
  let wire = Yojson.Safe.to_string transferred in
  let bytes = "\r\n" ^ wire ^ "\r\n \t\n" ^ wire ^ "\n" in
  prepare base bytes;
  let before = inspect base in
  check_decision "blank CRLF and duplicate-ID source remains adoptable" I.Adoption_required before;
  check_optional_string "digest covers all original bytes"
    (Some (Agent_core_sha256.(to_hex (digest_string bytes)))) (I.posts_source_sha256 before);
  let result = I.adopt_offline ~base_path:base ~expected_intent_sha256:(token before) in
  check_completed result;
  check_string "adoption preserves duplicate rows and original raw formatting"
    bytes (read_bytes (posts_path base));
  check_decision "successful current bytes are Ready" I.Ready_observed (inspect base)

let guard_wire generation =
  "{\"schema\":\"masc.board_posts_initialized.v1\",\"generation\":\"" ^ generation ^ "\"}\n"
let valid_generation = "0123456789abcdef0123456789abcdef"

let test_guard_schema base =
  prepare base "";
  let valid = guard_wire valid_generation in
  let schema = "schema", `String "masc.board_posts_initialized.v1" in
  let generation = "generation", `String valid_generation in
  let object_row fields = Yojson.Safe.to_string (`Assoc fields) ^ "\n" in
  let cases = [
    "empty", "";
    "blank", "\n";
    "extra blank row", valid ^ "\n";
    "extra object row", valid ^ valid;
    "torn", String.sub valid 0 (String.length valid - 1);
    "pretty multiline", "{\n\"schema\":\"masc.board_posts_initialized.v1\",\n\"generation\":\"" ^ valid_generation ^ "\"}\n";
    "duplicate schema", object_row [schema; schema; generation];
    "duplicate generation", object_row [schema; generation; generation];
    "unknown field", object_row [schema; generation; "prepared", `Bool true];
    "missing generation", object_row [schema];
    "non-string schema", object_row ["schema", `Int 1; generation];
    "non-string generation", object_row [schema; "generation", `Int 1];
    "non-object", "[]\n";
    "unsupported schema", object_row ["schema", `String "masc.other.v1"; generation];
    "uppercase generation", guard_wire "0123456789ABCDEF0123456789abcdef";
    "short generation", guard_wire "0123456789abcdef";
    "padded generation", guard_wire (" " ^ valid_generation);
    "invalid JSON", "{\n" ] in
  List.iter (fun (label, bytes) ->
    write_bytes (guard_path base) bytes;
    let before = state (guard_path base) in
    check_refused (inspect base);
    check_bool (label ^ " guard is untouched") true
      (before = state (guard_path base))) cases;
  write_bytes (guard_path base) (object_row [generation; schema]);
  let ready = inspect base in
  check_decision "exact fields may appear in either order" I.Ready_observed ready;
  check_dependents_not_examined ready;
  Unix.unlink (posts_path base);
  check_refused (inspect base)

let test_rejected_posts base =
  let row = actual_post_row base |> Yojson.Safe.to_string in
  prepare base (row ^ "\n{}\n");
  let malformed = inspect base in
  check_refused malformed;
  check_bool "complete malformed bytes retain forensic digest" true
    (Option.is_some (I.posts_source_sha256 malformed));
  write_bytes (posts_path base) (row ^ "\n{");
  let before = state (posts_path base) in
  let torn = inspect base in
  check_refused torn;
  check_optional_string "torn source has no full raw digest" None
    (I.posts_source_sha256 torn);
  check_bool "inspection never recovers torn bytes" true
    (before = state (posts_path base));
  check_strings "malformed observations create no locks"
    [Filename.basename (posts_path base)] (entries (workspace base))

let dependent_files = [Paths.Comments; Paths.Reactions; Paths.Sub_boards; Paths.Votes]

let test_dependent_survivors base =
  List.iteri (fun index family ->
    let root = Filename.concat base (string_of_int index) in
    Unix.mkdir root 0o750;
    Unix.mkdir (workspace root) 0o750;
    let survivor = Paths.file_path ~workspace_masc_dir:(workspace root) family in
    write_bytes survivor "";
    let before = state survivor in
    check_refused (inspect root);
    check_bool "surviving empty dependent is untouched" true (before = state survivor);
    Unix.unlink survivor;
    Unix.mkdir survivor 0o750;
    check_refused (inspect root);
    Unix.rmdir survivor;
    let target = Filename.concat root "absent-dependent-target" in
    Unix.symlink target survivor;
    check_refused (inspect root);
    check_bool "dangling dependent target stays absent" true (absent target);
    Unix.unlink survivor;
    check_decision "actual removal permits new explicit bootstrap intent"
      I.Bootstrap_required (inspect root)) dependent_files

let test_unrelated_dependents_not_examined base =
  prepare base "";
  List.iteri (fun index family ->
    let path = Paths.file_path ~workspace_masc_dir:(workspace base) family in
    match index with
    | 0 -> write_bytes path "malformed unrelated bytes"
    | 1 -> Unix.mkdir path 0o000
    | 2 -> Unix.symlink (Filename.concat base "missing-unrelated") path
    | _ -> Unix.mkfifo path 0o600) dependent_files;
  let before = entries (workspace base) in
  let adoptable = inspect base in
  check_decision "unrelated survivors do not forbid adoption" I.Adoption_required adoptable;
  check_dependents_not_examined adoptable;
  check_completed (I.adopt_offline ~base_path:base ~expected_intent_sha256:(token adoptable));
  let ready = inspect base in
  check_decision "unrelated survivors do not forbid Ready observation" I.Ready_observed ready;
  check_dependents_not_examined ready;
  List.iter (fun name ->
    check_bool "unrelated survivor was preserved" true
      (List.mem name (entries (workspace base)))) before;
  Unix.chmod (Paths.file_path ~workspace_masc_dir:(workspace base) Paths.Reactions) 0o750

let test_late_bootstrap_survivor base =
  let expected = token (inspect base) in
  Unix.mkdir (workspace base) 0o750;
  let survivor = Paths.file_path ~workspace_masc_dir:(workspace base) Paths.Comments in
  write_bytes survivor "";
  let before = state survivor in
  let outcome = I.bootstrap_offline ~base_path:base ~expected_intent_sha256:expected in
  check_incomplete outcome;
  check_effect outcome "posts" "unchanged";
  check_effect outcome "guard" "unchanged";
  check_bool "apply rechecks surviving dependent before data writes" true
    (before = state survivor);
  check_strings "refused bootstrap creates no stable lock or stage"
    [Filename.basename survivor] (entries (workspace base))

let test_bootstrap_and_generation base =
  let initial = inspect base in
  let expected = token initial in
  let result = I.bootstrap_offline ~base_path:base ~expected_intent_sha256:expected in
  check_completed result;
  check_effect result "posts" "confirmed_now";
  check_effect result "guard" "confirmed_now";
  check_string "bootstrap creates actual Present(empty) posts" "" (read_bytes (posts_path base));
  let guard_before = state (guard_path base) in
  let guard = read_bytes (guard_path base) in
  check_bool "writer emits one LF terminated row" true
    (String.length guard > 0 && guard.[String.length guard - 1] = '\n');
  let row = Yojson.Safe.from_string guard in
  check_string "writer emits current schema" "masc.board_posts_initialized.v1"
    (row |> json_member "schema" |> json_string);
  let generation = row |> json_member "generation" |> json_string in
  check_int "128-bit generation encoded as lowercase hex" 32 (String.length generation);
  check_bool "generation has exact ASCII lowercase hex alphabet" true
    (String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) generation);
  let ready = inspect base in
  check_decision "bootstrap bytes are Ready" I.Ready_observed ready;
  let repeated = I.bootstrap_offline ~base_path:base ~expected_intent_sha256:expected in
  check_incomplete repeated;
  check_effect repeated "posts" "unchanged";
  check_effect repeated "guard" "unchanged";
  let adopted = I.adopt_offline ~base_path:base ~expected_intent_sha256:expected in
  check_incomplete adopted;
  check_bool "repeat attempts never remint or replace generation" true
    (guard_before = state (guard_path base))

let test_stale_content_and_same_byte_replacement base =
  prepare base " \n";
  let before = inspect base in
  let expected = token before in
  write_bytes (posts_path base) "\t\n";
  let stale = I.adopt_offline ~base_path:base ~expected_intent_sha256:expected in
  check_incomplete stale;
  check_effect stale "posts" "unchanged";
  check_bool "stale token cannot publish guard" true (absent (guard_path base));
  write_bytes (posts_path base) " \n";
  let original_inode = (Unix.lstat (posts_path base)).Unix.st_ino in
  let replacement = Filename.concat (workspace base) "replacement.jsonl" in
  write_bytes replacement " \n";
  Unix.rename replacement (posts_path base);
  check_bool "fixture actually replaces source inode" false
    (original_inode = (Unix.lstat (posts_path base)).Unix.st_ino);
  check_string "identical raw content preserves logical intent"
    expected (token (inspect base));
  check_completed (I.adopt_offline ~base_path:base ~expected_intent_sha256:expected);
  check_string "fresh real snapshot adopts replacement bytes" " \n" (read_bytes (posts_path base))

let test_replaced_root_stales_intent base =
  let root = Filename.concat base "selected" in
  Unix.mkdir root 0o750;
  let expected = token (inspect root) in
  let saved = Filename.concat base "former-root" in
  Unix.rename root saved;
  Unix.mkdir root 0o750;
  check_bool "new physical root gets a new intent" false
    (expected = token (inspect root));
  let result = I.bootstrap_offline ~base_path:root ~expected_intent_sha256:expected in
  check_incomplete result;
  check_effect result "posts" "unchanged";
  check_effect result "guard" "unchanged";
  check_bool "stale physical root did not create data" true (absent (posts_path root));
  check_bool "former physical root stayed untouched" true (absent (workspace saved))

let () =
  let case name test = Alcotest.test_case name `Quick (with_fixture test) in
  Alcotest.run "board_posts_initialization" [
    "noncreating observations", [
      case "absent root refuses and inspect creates no metadata" test_absent_root_and_noncreating_inspect;
      case "physical aliases and parent creation preserve intent" test_aliases_and_missing_directory_token;
      case "external workspace alias refuses" (test_workspace_alias false);
      case "dangling workspace alias refuses" (test_workspace_alias true);
      case "Missing differs from Present(empty)" test_missing_and_present_empty;
      case "raw formatting duplicates and producer transfer survive adoption" test_raw_content_adoption;
      case "guard requires exactly one strict physical row" test_guard_schema;
      case "partial and torn posts have no mutation intent" test_rejected_posts;
      case "all dependent survivors forbid bootstrap" test_dependent_survivors;
      case "adoption and Ready skip unrelated families" test_unrelated_dependents_not_examined;
      ];
    "explicit effects", [
      case "bootstrap writes once and preserves generation" test_bootstrap_and_generation;
      case "stale content refuses but same bytes use a fresh snapshot" test_stale_content_and_same_byte_replacement;
      case "physical root replacement stales intent" test_replaced_root_stales_intent;
      case "apply rechecks a late bootstrap dependent survivor" test_late_bootstrap_survivor;
      case "raw posts digest is not a rooted action token" test_raw_digest_is_not_mutation_intent ] ]
