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
    Fs_compat.mkdir_p seed;
    let module Preparation = Masc_test_deps.Board_test_preparation in
    Preparation.prepare ~base_path:seed ~action:Preparation.Bootstrap;
    let store = Board.create_store ~base_path:seed () in
    (match Rows.load_persisted_posts store with
     | Ok 0 -> ()
     | Ok _ | Error _ -> Alcotest.fail "initialized producer did not load an empty source");
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

let test_leaf_bindings base =
  prepare base "";
  write_bytes (guard_path base) (guard_wire valid_generation);
  List.iter (fun path ->
    let original = read_bytes path in
    let outside = Filename.concat base "external-leaf" in
    Unix.rename path outside;
    let before = state outside in
    Unix.symlink outside path;
    check_refused (inspect base);
    check_bool "leaf alias target is untouched" true (before = state outside);
    check_string "leaf alias remains in place" outside (Unix.readlink path);
    Unix.unlink path;
    Unix.link outside path;
    check_refused (inspect base);
    check_string "multiply-linked bytes are preserved" original (read_bytes outside);
    Unix.unlink path;
    Unix.rename outside path;
    check_decision "restored unique leaf is readable" I.Ready_observed (inspect base);
    Unix.unlink path;
    Unix.symlink (Filename.concat base "missing-leaf-target") path;
    check_refused (inspect base);
    Unix.unlink path;
    write_bytes path original) [posts_path base; guard_path base]

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

let test_raw_digest_is_not_mutation_intent base =
  prepare base "";
  let observed = inspect base in
  let raw = match I.posts_source_sha256 observed with
    | Some sha -> sha
    | None -> Alcotest.fail "actual Present(empty) lacked its raw digest" in
  check_bool "raw content evidence differs from rooted action intent" false
    (String.equal raw (token observed));
  let result = I.adopt_offline ~base_path:base ~expected_intent_sha256:raw in
  check_incomplete result;
  check_effect result "posts" "unchanged";
  check_effect result "guard" "unchanged";
  check_bool "raw digest never grants guard publication" true (absent (guard_path base))

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

type fault_kind = Ordinary | Timeout | Nested_timeout
type target = Posts | Guard
type fault_site = Stable_lock_close | Rewrite_parent_sync

let fault_exception = function
  | Ordinary -> Failure "actual offline transaction fault"
  | Timeout -> Eio.Time.Timeout
  | Nested_timeout ->
    let backtrace = Printexc.get_callstack 16 in
    fst (Eio.Exn.combine
      (Failure "ordinary nested transaction member", backtrace) (Eio.Time.Timeout, backtrace))

let raise_captured exception_ captured =
  try raise exception_ with actual ->
    let backtrace = Printexc.get_raw_backtrace () in
    captured := Some backtrace;
    Printexc.raise_with_backtrace actual backtrace

let unix_io : Fs_compat.private_jsonl_transaction_io_for_testing = {
  before_sync_parent = (fun _ -> ()); close_fd = Unix.close;
}
let unix_files : I.For_testing.file_io = { posts = unix_io; guard = unix_io }

let fault_io ~base ~target ~site ~exception_ ~captured ~calls =
  let path = match target with Posts -> posts_path base | Guard -> guard_path base in
  match site with
  | Rewrite_parent_sync -> { unix_io with before_sync_parent = (fun directory ->
      check_string "hook receives the actual published parent" (workspace base) directory;
      incr calls;
      raise_captured exception_ captured) }
  | Stable_lock_close -> { unix_io with close_fd = (fun descriptor ->
      let actual = Unix.fstat descriptor in
      let stable = Unix.stat (Fs_compat.private_jsonl_lock_path path) in
      let is_stable = actual.Unix.st_dev = stable.Unix.st_dev
        && actual.Unix.st_ino = stable.Unix.st_ino in
      Unix.close descriptor;
      if is_stable then (incr calls; raise_captured exception_ captured)) }

let check_backtrace captured actual =
  let original = match !captured with
    | Some backtrace -> backtrace
    | None -> Alcotest.fail "real fault did not capture its original raising frames" in
  let length = Printexc.raw_backtrace_length original in
  check_bool "actual raising origin has frames" true (length > 0);
  check_bool "finish retains all original raising frames" true
    (Printexc.raw_backtrace_length actual >= length);
  for index = 0 to length - 1 do
    check_bool "finish retains the original frame prefix" true
      (Printexc.get_raw_backtrace_slot original index = Printexc.get_raw_backtrace_slot actual index)
  done

let expect_reserved exception_ captured finish =
  let raised = try finish (); None
    with actual -> Some (actual, Printexc.get_raw_backtrace ()) in
  match raised with
  | None -> Alcotest.fail "retained original reserved exception was swallowed"
  | Some (actual, backtrace) ->
    check_bool "original outer reserved exception is preserved" true (actual == exception_);
    check_backtrace captured backtrace

let test_write_fault target site kind base =
  prepare base "";
  let expected = token (inspect base) in
  let exception_ = fault_exception kind in
  let captured = ref None and calls = ref 0 in
  let injected = fault_io ~base ~target ~site ~exception_ ~captured ~calls in
  let write : I.For_testing.file_io = match target with
    | Posts -> { unix_files with posts = injected }
    | Guard -> { unix_files with guard = injected } in
  let io : I.For_testing.io = { read = unix_files; write } in
  let outcome = I.For_testing.adopt_offline ~base_path:base ~expected_intent_sha256:expected ~io in
  check_int "exactly one real injected transaction boundary" 1 !calls;
  let field = match target with Posts -> "posts" | Guard -> "guard" in
  check_diagnostic outcome field;
  let posts, guard, guard_present, completed, restart = match target, site, kind with
    | (Posts | Guard), Stable_lock_close, Ordinary ->
      "confirmed_now", "confirmed_now", true, I.Completed, I.Ready_observed
    | Posts, Stable_lock_close, (Timeout | Nested_timeout) ->
      "confirmed_now", "unchanged", false, I.Not_completed, I.Adoption_required
    | Posts, Rewrite_parent_sync, (Ordinary | Timeout | Nested_timeout) ->
      "effect_unknown", "unchanged", false, I.Not_completed, I.Adoption_required
    | Guard, Stable_lock_close, (Timeout | Nested_timeout) ->
      "confirmed_now", "confirmed_now", true, I.Not_completed, I.Ready_observed
    | Guard, Rewrite_parent_sync, (Ordinary | Timeout | Nested_timeout) ->
      "confirmed_now", "effect_unknown", true, I.Not_completed, I.Ready_observed in
  check_effect outcome "posts" posts;
  check_effect outcome "guard" guard;
  check_bool "actual completion" true (I.completion outcome = completed);
  check_bool "next effect follows the known prefix" guard_present (not (absent (guard_path base)));
  check_string "all attempts retain exact adopted posts bytes" "" (read_bytes (posts_path base));
  let before_posts = state (posts_path base) in
  let before_guard = if absent (guard_path base) then None else Some (state (guard_path base)) in
  (match kind with
   | Ordinary -> check_bool "finish agrees" true (I.finish_outcome outcome = completed)
   | Timeout | Nested_timeout ->
     expect_reserved exception_ captured (fun () -> ignore (I.finish_outcome outcome)));
  check_bool "pure finish does not touch posts" true (before_posts = state (posts_path base));
  check_bool "pure finish does not create or rewrite guard" true
    (before_guard = if absent (guard_path base) then None else Some (state (guard_path base)));
  check_decision "restart observes only current bytes" restart (inspect base);
  check_bool "restart cannot settle the earlier invocation" true (I.completion outcome = completed)

let test_inspection_reserved kind base =
  prepare base "";
  let exception_ = fault_exception kind in
  let captured = ref None and calls = ref 0 in
  let posts : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> Alcotest.fail "noncreating inspection attempted a parent sync");
    close_fd = (fun descriptor ->
      Unix.close descriptor; incr calls; raise_captured exception_ captured);
  } in
  let io : I.For_testing.file_io = { unix_files with posts } in
  let observed = I.For_testing.inspect ~base_path:base ~io in
  check_int "one actual readonly descriptor settlement" 1 !calls;
  check_strings "reserved inspection creates no lock or guard"
    [Filename.basename (posts_path base)] (entries (workspace base));
  expect_reserved exception_ captured (fun () -> I.finish_inspection observed)

let test_reserved_guard_preparation kind base =
  prepare base " \n";
  let expected = token (inspect base) in
  let before = state (posts_path base) in
  let exception_ = fault_exception kind in
  let captured = ref None and calls = ref 0 in
  let guard = fault_io ~base ~target:Guard ~site:Stable_lock_close ~exception_ ~captured ~calls in
  let read : I.For_testing.file_io = { unix_files with guard } in
  let io : I.For_testing.io = { read; write = unix_files } in
  let result = I.For_testing.adopt_offline ~base_path:base ~expected_intent_sha256:expected ~io in
  check_int "fault belongs to actual guard stable-read settlement" 1 !calls;
  check_incomplete result;
  check_effect result "posts" "unchanged";
  check_effect result "guard" "unchanged";
  (match I.outcome_to_yojson result |> json_member "preparation"
      |> json_member "guard" |> json_member "diagnostics" with
   | `List (_ :: _) -> ()
   | `List [] -> Alcotest.fail "actual preparation cleanup diagnostic was discarded"
   | _ -> Alcotest.fail "preparation diagnostics are not an array");
  check_bool "guard preparation settles before posts rewrite" true
    (before = state (posts_path base));
  check_bool "failed preparation does not publish guard" true (absent (guard_path base));
  expect_reserved exception_ captured (fun () -> ignore (I.finish_outcome result))

let () =
  Printexc.record_backtrace true;
  let case name test = Alcotest.test_case name `Quick (with_fixture test) in
  let fault_cases = List.concat_map (fun (target_name, target) ->
    List.concat_map (fun (site_name, site) ->
      List.map (fun (kind_name, kind) ->
        case (target_name ^ " " ^ site_name ^ " " ^ kind_name)
          (test_write_fault target site kind))
        ["ordinary", Ordinary; "timeout", Timeout; "nested timeout", Nested_timeout])
      ["stable close", Stable_lock_close; "published parent sync", Rewrite_parent_sync])
    ["posts", Posts; "guard", Guard] in
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
      case "both leaves refuse aliases and multiply linked files" test_leaf_bindings ];
    "explicit effects", [
      case "bootstrap writes once and preserves generation" test_bootstrap_and_generation;
      case "stale content refuses but same bytes use a fresh snapshot" test_stale_content_and_same_byte_replacement;
      case "physical root replacement stales intent" test_replaced_root_stales_intent;
      case "apply rechecks a late bootstrap dependent survivor" test_late_bootstrap_survivor;
      case "raw posts digest is not a rooted action token" test_raw_digest_is_not_mutation_intent ];
    "actual interrupted publication", fault_cases;
    "readonly reserved settlement", [
      case "direct timeout preserves original exception and frames" (test_inspection_reserved Timeout);
      case "nested timeout preserves original outer exception" (test_inspection_reserved Nested_timeout);
      case "direct timeout in guard preparation precedes all writes" (test_reserved_guard_preparation Timeout);
      case "nested timeout in guard preparation precedes all writes" (test_reserved_guard_preparation Nested_timeout) ] ]
