(** #10349 — pin the keeper FS path-rejection oracle removal.

    Pre-fix [resolve_keeper_read_path] returned errors of the
    form [path_not_found_under_allowed_roots: <p> (roots=[...])]
    where [<roots>] was the resolver-side view of the keeper's
    allowed sandbox roots.  Combined with the keeper identity
    drift documented in the issue (turn 433 trace: contract
    layer claimed [masc-improver/Docker] while the resolver
    enumerated [analyst]'s sandbox), the trailing roots list
    became a side-channel oracle: the LLM driving keeper A
    could observe sibling keeper B's directory layout via the
    error string.

    The user-visible message is now opaque
    ([path_not_found_under_allowed_roots: <p>]) and the
    rejection signal is preserved on the operator side via
    [masc_keeper_path_rejection_total{kind}].

    Tests pin:
    1. Outside-sandbox rejection: error has no resolver roots.
    2. Out-of-roots rejection: error has no [roots=] substring.
    3. Not-found-relative rejection: same.
    4. Counter labels: each kind ticks its own label.
    5. The legacy prefix [path_not_found_under_allowed_roots:]
       remains, so existing classifiers and circuit breaker
       matchers keep recognising the error class. *)

open Alcotest
open Masc_mcp

let counter = ref 0

let mk_dir prefix =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%d_%.0f" prefix !counter (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  (try Unix.mkdir dir 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let git_dir = Filename.concat dir ".git" in
  (try Unix.mkdir git_dir 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let lib_dir = Filename.concat dir "lib" in
  (try Unix.mkdir lib_dir 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun n -> rm_rf (Filename.concat path n));
      Unix.rmdir path)
    else Sys.remove path

let with_clean_env f =
  let saved = try Some (Sys.getenv "MASC_BASE_PATH") with Not_found -> None in
  Unix.putenv "MASC_BASE_PATH" "";
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some v -> Unix.putenv "MASC_BASE_PATH" v
      | None -> Unix.putenv "MASC_BASE_PATH" "")
    f

let counter_value labels =
  Prometheus.metric_value_or_zero
    Prometheus.metric_keeper_path_rejection
    ~labels ()

let assert_no_roots_leak msg err =
  check bool (msg ^ ": no '(roots=' substring") false
    (Astring.String.is_infix ~affix:"(roots=" err);
  check bool (msg ^ ": no 'roots=[' substring") false
    (Astring.String.is_infix ~affix:"roots=[" err);
  check bool (msg ^ ": no sandbox roots substring") false
    (Astring.String.is_infix ~affix:"sandbox roots:" err);
  check bool (msg ^ ": no resolved path hint") false
    (Astring.String.is_infix ~affix:"resolved=" err)

let assert_legacy_not_found_prefix msg err =
  check bool (msg ^ ": legacy prefix preserved") true
    (Astring.String.is_prefix
       ~affix:"path_not_found_under_allowed_roots:" err)

(* --- 1. outside-sandbox rejection: opaque error + counter --- *)

let test_path_outside_sandbox_no_leak () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_clean_env @@ fun () ->
  let dir = mk_dir "kpath_sandbox" in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Coord.default_config dir in
      let labels = [ ("kind", "out_of_roots") ] in
      let before = counter_value labels in
      let result =
        Keeper_alerting_path.resolve_keeper_read_path ~config
          ~allowed_paths:[ "lib" ] ~raw_path:"README.md"
      in
      check bool "rejection occurred" true (Result.is_error result);
      let err = Result.get_error result in
      assert_no_roots_leak "path_outside_sandbox" err;
      check bool "path_outside_sandbox prefix preserved" true
        (Astring.String.is_prefix ~affix:"path_outside_sandbox:" err);
      check bool "allowed root path is not leaked" false
        (Astring.String.is_infix ~affix:(Filename.concat dir "lib") err);
      check (float 0.0001) "out_of_roots counter +1"
        (before +. 1.0)
        (counter_value labels))

(* --- 2. out-of-roots rejection: opaque error + counter --- *)

let test_out_of_roots_no_leak () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_clean_env @@ fun () ->
  let dir = mk_dir "kpath_out" in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Coord.default_config dir in
      let labels = [ ("kind", "out_of_roots") ] in
      let before = counter_value labels in
      (* Absolute path inside root with trailing slash and a
         missing leaf → bypasses [allows_missing_leaf_read]
         (which only forgives parent-exists/non-slash paths)
         and falls into the out_of_roots branch. *)
      let target = Filename.concat dir "lib/never_exists_10349/" in
      let result =
        Keeper_alerting_path.resolve_keeper_read_path ~config
          ~allowed_paths:[ "lib" ] ~raw_path:target
      in
      check bool "rejection occurred" true (Result.is_error result);
      let err = Result.get_error result in
      assert_no_roots_leak "out_of_roots" err;
      assert_legacy_not_found_prefix "out_of_roots" err;
      check (float 0.0001) "out_of_roots counter +1"
        (before +. 1.0)
        (counter_value labels))

(* --- 3. not-found-relative rejection: opaque + counter --- *)

let test_not_found_relative_no_leak () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_clean_env @@ fun () ->
  let dir = mk_dir "kpath_rel" in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Coord.default_config dir in
      let labels = [ ("kind", "not_found_relative") ] in
      let before = counter_value labels in
      let result =
        Keeper_alerting_path.resolve_keeper_read_path ~config
          ~allowed_paths:[] ~raw_path:"nonexistent_repo_10349/"
      in
      check bool "rejection occurred" true (Result.is_error result);
      let err = Result.get_error result in
      assert_no_roots_leak "not_found_relative" err;
      assert_legacy_not_found_prefix "not_found_relative" err;
      check (float 0.0001) "not_found_relative counter +1"
        (before +. 1.0)
        (counter_value labels))

(* --- 4. counter labels are isolated per kind ------------- *)

let test_counter_labels_isolated () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_clean_env @@ fun () ->
  let dir = mk_dir "kpath_iso" in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Coord.default_config dir in
      let other_labels = [ ("kind", "out_of_roots") ] in
      let before_other = counter_value other_labels in
      let _ =
        Keeper_alerting_path.resolve_keeper_read_path ~config
          ~allowed_paths:[] ~raw_path:"definitely_missing_10349/"
      in
      check (float 0.0001)
        "out_of_roots counter unaffected by not_found_relative bump"
        before_other
        (counter_value other_labels))

let () =
  run "keeper_path_roots_leak_10349"
    [
      ( "no-roots-leak",
        [
          test_case "path_outside_sandbox error is opaque" `Quick
            test_path_outside_sandbox_no_leak;
          test_case "out_of_roots error is opaque" `Quick
            test_out_of_roots_no_leak;
          test_case "not_found_relative error is opaque" `Quick
            test_not_found_relative_no_leak;
        ] );
      ( "counter-labels",
        [
          test_case "kinds tick independent label series" `Quick
            test_counter_labels_isolated;
        ] );
    ]
