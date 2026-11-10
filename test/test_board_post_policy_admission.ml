open Masc

let require = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.show_board_error error)

let loaded store =
  require (Board.initialize_store store);
  require (Board.require_posts_source_readable store);
  ignore (require (Board.read_sub_boards store));
  store

let fresh base = loaded (Board.create_store ~base_path:base ())

let create store ?hearth ?(author="outsider") content =
  Board.create_post store ~lookup:Recipient_lookup.none_declared ~author ~content
    ~post_kind:Board.Human_post ~visibility:Board.Public ?hearth ~ttl_hours:0 ()

let created = function
  | Ok post -> post
  | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error)

type refusal = Source_unavailable | Policy_denied

let expect_refusal expected = function
  | Ok _ -> Alcotest.fail "stale or forbidden policy admitted a new post"
  | Error failure ->
    Alcotest.(check bool) "refusal precedes the append" true
      (Board.Post_publication_failure.effect_disposition failure = Failure_effect.Proven_pre_effect);
    Alcotest.(check bool) "no committed post receipt" true
      (Option.is_none (Board.Post_publication_failure.committed failure));
    match Board.Post_publication_failure.cause failure with
    | Board.Post_publication_failure.Raised exn -> Alcotest.fail (Printexc.to_string exn)
    | Board.Post_publication_failure.Board_error error ->
      let actual = match error with
        | Board.Io_error _ -> Some Source_unavailable
        | Validation_error _ -> Some Policy_denied
        | Invalid_id _ | Post_not_found _ | Comment_not_found _ | Already_voted _
        | Already_exists _ | Unauthorized _ -> None in
      Alcotest.(check bool) "actual source/policy refusal" true (actual = Some expected)

let expect_io result =
  Alcotest.(check bool) "strict Policy authority refused" true (Result.is_error result)

let bytes path = if Sys.file_exists path then Some (Fs_compat.load_file path) else None
let same_bytes label before path = Alcotest.(check (option string)) label before (bytes path)

let scoped store =
  let board = require (Board.create_sub_board store ~slug:"post-policy"
    ~name:"Post policy" ~description:"real creation admission" ~owner:"owner"
    ~access:Board.Open ()) in
  ignore (created (create store ~hearth:board.slug "existing scoped post"));
  board

let restrict store (board : Board.sub_board) =
  ignore (require (Board.update_sub_board store
    ~sub_board_id:(Board.Sub_board_id.to_string board.Board.id) ~access:Board.Owner_only ()))

let test_foreign_restriction base =
  let first = fresh base in
  let board = scoped first in
  restrict (fresh base) board;
  let path = Board.persist_path first in
  let before = bytes path in
  expect_refusal Source_unavailable (create first ~hearth:board.slug "cached Open policy");
  same_bytes "foreign policy cannot authorize append" before path;
  Alcotest.(check int) "no rejected model row" 1 (Hashtbl.length first.posts);
  require (Board.require_posts_source_readable first);
  expect_io (Board.read_sub_boards first);
  expect_refusal Policy_denied (create (fresh base) ~hearth:board.slug "fresh restricted policy");
  let owner = created (create (fresh base) ~hearth:board.slug ~author:"owner" "current owner") in
  Alcotest.(check bool) "owner post survives restart" true
    (Hashtbl.mem (fresh base).posts (Board.Post_id.to_string owner.id))

let test_new_restricted_registration base =
  let first = fresh base in
  ignore (created (create first ~hearth:"unregistered" "valid unregistered hearth"));
  let other = fresh base in
  ignore (require (Board.create_sub_board other ~slug:"unregistered" ~name:"New policy"
    ~description:"previously absent" ~owner:"owner" ~access:Board.Owner_only ()));
  let path = Board.persist_path first in
  let before = bytes path in
  expect_refusal Source_unavailable (create first ~hearth:"unregistered" "old policy absence");
  same_bytes "policy absence was an actual dependency" before path;
  Alcotest.(check int) "restart has no rejected post" 1 (Hashtbl.length (fresh base).posts)

let test_unscoped_policy_unavailable base =
  let first = fresh base in
  let path = Board.sub_boards_path first in
  Unix.mkdir path 0o700;
  expect_io (Board.reload_sub_boards first);
  let post = created (create first "unscoped post needs no Policy file") in
  Unix.rmdir path;
  Alcotest.(check bool) "unscoped append survives restart" true
    (Hashtbl.mem (fresh base).posts (Board.Post_id.to_string post.id))

let same_inode left right =
  left.Unix.st_dev = right.Unix.st_dev && left.Unix.st_ino = right.Unix.st_ino

let contend path =
  match Fs_compat.append_private_jsonl_durable_stable_result path "\n" with
  | Error (Fs_compat.Stable_lock_contended _) -> exit 0
  | Error _ -> exit 2
  | Ok _ -> exit 3

let test_live_guards base =
  let initial = fresh base in
  let board = scoped initial in
  let path = Board.persist_path initial in
  let original_length = (Unix.stat path).Unix.st_size in
  let targets = [path; Board.sub_boards_path initial] in
  let observed = ref [] and armed = ref false in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      let stat = Unix.fstat fd in
      Unix.close fd;
      if !armed && same_inode stat (Unix.stat path) && stat.Unix.st_size > original_length then (
        armed := false;
        observed := List.map (fun target ->
          let exe = Sys.executable_name in
          let pid = Unix.create_process exe [|exe; "--contend-post-policy"; target|]
              Unix.stdin Unix.stdout Unix.stderr in
          match snd (Unix.waitpid [] pid) with
          | Unix.WEXITED 0 -> true
          | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false) targets))
  } in
  let first = loaded (Board.create_store_with_source_io_for_testing ~base_path:base
      ~io:{posts=Some io} ()) in
  armed := true;
  let post = created (create first ~hearth:board.slug "actual guarded append") in
  Alcotest.(check (list bool)) "both real stable locks held through data close"
    [true; true] !observed;
  Alcotest.(check bool) "guarded post survives restart" true
    (Hashtbl.mem (fresh base).posts (Board.Post_id.to_string post.id))

let expect_timeout operation = match operation () with
  | _ -> Alcotest.fail "reserved cleanup cause was lost"
  | exception Eio.Time.Timeout -> ()

let check_known first base =
  Alcotest.(check int) "known append published before reserved cleanup" 2 (Hashtbl.length first.Board.posts);
  require (Board.require_posts_source_readable first);
  Alcotest.(check int) "fresh store retains the known append" 2 (Hashtbl.length (fresh base).posts)

let test_known_policy_cleanup base =
  let initial = fresh base in
  let board = scoped initial in
  let lock_path = Fs_compat.private_jsonl_lock_path (Board.sub_boards_path initial) in
  let armed = ref false in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      let stat = Unix.fstat fd in Unix.close fd;
      if !armed && same_inode stat (Unix.stat lock_path) then (
        armed := false; raise Eio.Time.Timeout))
  } in
  let first = loaded (Board.create_store_with_sub_boards_io_for_testing ~base_path:base ~io ()) in
  armed := true;
  expect_timeout (fun () -> create first ~hearth:board.slug "known append before Policy cleanup");
  check_known first base

let test_known_data_cleanup base =
  let initial = fresh base in
  let board = scoped initial in
  let path = Board.persist_path initial in
  let original_length = (Unix.stat path).Unix.st_size in
  let armed = ref false in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      let stat = Unix.fstat fd in Unix.close fd;
      if !armed && same_inode stat (Unix.stat path) && stat.Unix.st_size > original_length then (
        armed := false; raise Eio.Time.Timeout))
  } in
  let first = loaded (Board.create_store_with_source_io_for_testing ~base_path:base
      ~io:{posts=Some io} ()) in
  armed := true;
  expect_timeout (fun () -> create first ~hearth:board.slug "known data close retains original IO");
  check_known first base;
  let diagnostics = match first.posts_source with
    | Board.Posts_readable {diagnostics;_} -> diagnostics
    | Posts_unobserved | Posts_refused _ | Posts_unsettled _ ->
      Alcotest.fail "known data close became unknown" in
  Alcotest.(check bool) "data cleanup stays a leaf diagnostic" true
    (List.exists (function
      | Board.File_diagnostic _ -> true
      | Workspace_diagnostic _ | Posts_guard_diagnostic _ | Raised_diagnostic _ -> false) diagnostics)

let test_refusal_outer_cleanup base =
  let initial = fresh base in
  let board = scoped initial in
  let lock_path = Fs_compat.private_jsonl_lock_path (Board.persist_path initial) in
  let armed = ref false in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      let stat = Unix.fstat fd in Unix.close fd;
      if !armed && same_inode stat (Unix.stat lock_path) then (
        armed := false; raise Eio.Time.Timeout))
  } in
  let first = loaded (Board.create_store_with_source_io_for_testing ~base_path:base
      ~io:{posts=Some io} ()) in
  restrict (fresh base) board;
  let before = bytes (Board.persist_path first) in
  armed := true;
  expect_timeout (fun () -> create first ~hearth:board.slug "Policy refusal plus outer cleanup");
  same_bytes "no append ran before reserved outer cleanup" before (Board.persist_path first);
  Alcotest.(check int) "no model publication on refusal" 1 (Hashtbl.length first.posts);
  require (Board.require_posts_source_readable first);
  expect_io (Board.read_sub_boards first);
  let diagnostics = match first.posts_source with
    | Board.Posts_readable {diagnostics;_} -> diagnostics
    | Posts_unobserved | Posts_refused _ | Posts_unsettled _ ->
      Alcotest.fail "known guard refusal invented an unknown Posts write" in
  let paths = List.filter_map (function
    | Board.Posts_guard_diagnostic failure -> Some failure.guard_path
    | File_diagnostic _ | Workspace_diagnostic _ | Raised_diagnostic _ -> None) diagnostics in
  Alcotest.(check (list string)) "inner refusal precedes outer cleanup"
    [Board.sub_boards_path first; Board.persist_path first] paths

let test_existing_curation_is_not_creation base =
  let initial = fresh base in
  let board = scoped initial in
  restrict (fresh base) board;
  let first = fresh base in
  let post = Hashtbl.fold (fun _ post _ -> Some post) first.posts None in
  let post = match post with Some post -> post | None -> Alcotest.fail "fixture post absent" in
  let post_id = Board.Post_id.to_string post.Board.id in
  require (Board.set_pinned first ~post_id ~pinned:true);
  require (Board.set_closed first ~post_id ~closed_by:"owner"
    ~successor:Board.No_successor ~summary:"curated" ());
  let restored = match Hashtbl.find_opt (fresh base).posts post_id with
    | Some post -> post | None -> Alcotest.fail "curated post absent" in
  Alcotest.(check bool) "curation does not require the old author to create again"
    true (restored.pinned && Option.is_some restored.closed)

let with_fixture test () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  let base = Filename.temp_dir "masc-post-policy-" "" in
  Fun.protect ~finally:(fun () ->
    Fs_compat.clear_fs ();
    match previous with
    | None -> Unix.unsetenv "MASC_BASE_PATH"
    | Some value -> Unix.putenv "MASC_BASE_PATH" value)
    (fun () -> Unix.putenv "MASC_BASE_PATH" base; test base)

let () = match Array.to_list Sys.argv with
  | [_; "--contend-post-policy"; path] -> contend path
  | _ ->
    Mirage_crypto_rng_unix.use_default ();
    Alcotest.run "Board post Policy admission" ["real sources", List.map
      (fun (name, test) -> Alcotest.test_case name `Quick (with_fixture test))
      ["foreign policy restriction", test_foreign_restriction;
       "new restricted registration", test_new_restricted_registration;
       "unscoped creation with unavailable Policy", test_unscoped_policy_unavailable;
       "live Posts and Policy guards", test_live_guards;
       "known append before Policy cleanup", test_known_policy_cleanup;
       "known data cleanup uses original IO", test_known_data_cleanup;
       "Policy refusal before outer cleanup", test_refusal_outer_cleanup;
       "existing curation is separate", test_existing_curation_is_not_creation]]
