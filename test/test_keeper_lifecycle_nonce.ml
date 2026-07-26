open Alcotest

module Nonce = Masc.Keeper_lifecycle_nonce
module Head = Fs_compat.Capability_head

let rec remove_tree path =
  match Unix.lstat path with
  | stat ->
    (match stat.Unix.st_kind with
     | Unix.S_DIR ->
       Sys.readdir path
       |> Array.iter (fun leaf -> remove_tree (Filename.concat path leaf));
       Unix.rmdir path
     | _ -> Unix.unlink path)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let rec mkdir_p path =
  if String.equal path "" || String.equal path Filename.current_dir_name
  then ()
  else if Sys.file_exists path
  then ()
  else (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o700)
;;

let with_base prefix fn =
  let base_path = Filename.temp_file prefix ".tmp" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Unix.mkdir (Filename.concat base_path ".masc") 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () -> fn base_path)
;;

let require_ok = function
  | Ok value -> value
  | Error error -> fail (Nonce.error_to_string error)
;;

let next ?floor ~base_path ~keeper_id ~owner_id () =
  Nonce.next_for_base_path
    ~base_path
    ~keeper_id
    ~owner_id
    ?floor
    ()
  |> require_ok
;;

let save_raw path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () ->
       output_string channel content;
       output_char channel '\n';
       close_out channel);
  Unix.chmod path 0o600
;;

let authority_path ~base_path ~keeper_id =
  Filename.concat
    (Nonce.For_testing.root_path_for_base_path ~base_path)
    (Nonce.For_testing.authority_leaf ~keeper_id)
;;

let test_restart_stable_monotonic () =
  with_base "masc_lifecycle_nonce_restart_" @@ fun base_path ->
  let first = next ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" () in
  let second = next ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" () in
  check int64 "fresh allocation" 1L first;
  check int64 "reopened authority advances" 2L second
;;

let test_floor_and_pair_independence () =
  with_base "masc_lifecycle_nonce_floor_" @@ fun base_path ->
  let floored =
    next
      ~floor:7L
      ~base_path
      ~keeper_id:"keeper-a"
      ~owner_id:"trace-a"
      ()
  in
  let advanced = next ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" () in
  let next_lifecycle =
    next ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-b" ()
  in
  let other_keeper =
    next ~base_path ~keeper_id:"keeper-b" ~owner_id:"trace-a" ()
  in
  check int64 "explicit floor" 7L floored;
  check int64 "successor after floor" 8L advanced;
  check int64 "new lifecycle continues keeper authority" 9L next_lifecycle;
  check int64 "keeper has independent authority" 1L other_keeper
;;

let test_concurrent_allocations_are_exclusive () =
  with_base "masc_lifecycle_nonce_concurrent_" @@ fun base_path ->
  let left = ref None in
  let right = ref None in
  Eio.Fiber.both
    (fun () ->
      left :=
        Some (next ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" ()))
    (fun () ->
      right :=
        Some (next ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-b" ()));
  let require_result side = function
    | Some value -> value
    | None -> failf "%s allocation did not complete" side
  in
  let left = require_result "left" !left in
  let right = require_result "right" !right in
  check
    (list int64)
    "concurrent callers receive distinct monotonic values"
    [ 1L; 2L ]
    (List.sort Int64.compare [ left; right ])
;;

let test_keeper_id_surrounding_whitespace_is_rejected () =
  with_base "masc_lifecycle_nonce_keeper_id_" @@ fun base_path ->
  List.iter
    (fun keeper_id ->
      match
        Nonce.next_for_base_path
          ~base_path
          ~keeper_id
          ~owner_id:"trace-a"
          ()
      with
      | Error Nonce.Invalid_keeper_id -> ()
      | Error error ->
        failf
          "unexpected keeper identity error for %S: %s"
          keeper_id
          (Nonce.error_to_string error)
      | Ok nonce ->
        failf
          "noncanonical keeper identity %S allocated nonce %Ld"
          keeper_id
          nonce)
    [ " keeper-a"; "keeper-a " ];
  check
    bool
    "invalid aliases do not create authority root"
    false
    (Fs_compat.file_exists
       (Nonce.For_testing.root_path_for_base_path ~base_path))
;;

let test_schema_mismatch_fails_closed () =
  with_base "masc_lifecycle_nonce_schema_" @@ fun base_path ->
  ignore
    (next ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" () : int64);
  let path =
    authority_path ~base_path ~keeper_id:"keeper-a"
  in
  save_raw
    path
    {|{"schema":"masc.keeper-lifecycle-nonce.v0","keeper_id":"keeper-a","allocated_to":"trace-a","nonce":1,"checksum_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}|};
  match
    Nonce.next_for_base_path
      ~base_path
      ~keeper_id:"keeper-a"
      ~owner_id:"trace-a"
      ()
  with
  | Error (Nonce.Corrupt_current (Nonce.Unsupported_schema observed)) ->
    check
      string
      "unsupported schema is preserved"
      "masc.keeper-lifecycle-nonce.v0"
      observed
  | Error error ->
    failf "unexpected schema error: %s" (Nonce.error_to_string error)
  | Ok value -> failf "unsupported schema allocated nonce %Ld" value
;;

let test_checksum_tamper_fails_closed () =
  with_base "masc_lifecycle_nonce_checksum_" @@ fun base_path ->
  ignore
    (next ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" () : int64);
  let path =
    authority_path ~base_path ~keeper_id:"keeper-a"
  in
  save_raw
    path
    {|{"schema":"masc.keeper-lifecycle-nonce.v1","keeper_id":"keeper-a","allocated_to":"trace-a","nonce":2,"checksum_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}|};
  match
    Nonce.next_for_base_path
      ~base_path
      ~keeper_id:"keeper-a"
      ~owner_id:"trace-a"
      ()
  with
  | Error (Nonce.Corrupt_current Nonce.Checksum_mismatch) -> ()
  | Error error ->
    failf "unexpected checksum error: %s" (Nonce.error_to_string error)
  | Ok value -> failf "checksum tamper allocated nonce %Ld" value
;;

let test_legacy_generation_is_ignored () =
  with_base "masc_lifecycle_nonce_legacy_" @@ fun base_path ->
  let legacy_dir =
    Filename.concat
      (Filename.concat
         (Filename.concat (Filename.concat base_path ".masc") "keepers")
         "keeper-a")
      "episodes"
  in
  mkdir_p legacy_dir;
  let legacy_path = Filename.concat legacy_dir "trace-a.generation" in
  let channel = open_out_bin legacy_path in
  output_string channel "999\n";
  close_out channel;
  let allocated =
    next ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" ()
  in
  check int64 "legacy generation is not an input" 1L allocated
;;

let test_read_settlement_warning_fails_closed () =
  with_base "masc_lifecycle_nonce_read_warning_" @@ fun base_path ->
  (match
     Nonce.For_testing.with_read_settlement_warning
       ~base_path
       ~keeper_id:"keeper-a"
       ~owner_id:"trace-a"
       ()
   with
   | Error
       (Nonce.Head_read_settlement_failed
          { row = None; observed_nonce = Some 0L; warnings = _ :: _; _ }) ->
     ()
   | Error error ->
     failf "unexpected read settlement error: %s" (Nonce.error_to_string error)
   | Ok nonce -> failf "read settlement warning allocated nonce %Ld" nonce);
  check
    int64
    "read warning did not consume nonce"
    1L
    (next ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" ())
;;

let test_publication_warning_retains_consumed_nonce () =
  with_base "masc_lifecycle_nonce_publish_warning_" @@ fun base_path ->
  (match
     Nonce.For_testing.with_publication_settlement_warning
       ~base_path
       ~keeper_id:"keeper-a"
       ~owner_id:"trace-a"
       ()
   with
   | Error (Nonce.Published_with_warnings { nonce = 1L; warnings = _ :: _; _ }) ->
     ()
   | Error error ->
     failf "unexpected publication settlement error: %s" (Nonce.error_to_string error)
   | Ok nonce -> failf "publication warning returned clean nonce %Ld" nonce);
  check
    int64
    "published warning consumed nonce"
    2L
    (next ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" ())
;;

let test_published_failure_retains_consumed_nonce () =
  with_base "masc_lifecycle_nonce_published_failure_" @@ fun base_path ->
  (match
     Nonce.For_testing.with_published_failure
       ~base_path
       ~keeper_id:"keeper-a"
       ~owner_id:"trace-a"
       ()
   with
   | Error
       (Nonce.Published_with_failure
          { nonce = 1L
          ; failure = { Head.target_effect = Head.Published _; _ }
          }) ->
     ()
   | Error error ->
     failf "unexpected published failure: %s" (Nonce.error_to_string error)
   | Ok nonce -> failf "published failure returned clean nonce %Ld" nonce);
  check
    int64
    "published failure consumed nonce"
    2L
    (next ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" ())
;;

let test_contention_retry_budget_is_finite () =
  with_base "masc_lifecycle_nonce_contention_" @@ fun base_path ->
  (match
     Nonce.For_testing.with_forced_conflicts
       ~base_path
       ~keeper_id:"keeper-a"
       ~owner_id:"trace-a"
       ()
   with
   | Error
       (Nonce.Contention_exhausted
          { attempts = 3
          ; last_failure =
              { Head.error = Head.Conflict _
              ; target_effect = Head.Unchanged
              ; _
              }
          }) ->
     ()
   | Error error ->
     failf "unexpected contention result: %s" (Nonce.error_to_string error)
   | Ok nonce -> failf "contention exhaustion returned nonce %Ld" nonce);
  check
    int64
    "three bounded attempts published three competing nonces"
    4L
    (next ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" ())
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Nonce.For_testing.enable_fd_backed_parent_opening ();
  run
    "keeper lifecycle nonce"
    [ ( "allocator"
      , [ test_case
            "restart stable monotonic"
            `Quick
            test_restart_stable_monotonic
        ; test_case
            "floor and pair independence"
            `Quick
            test_floor_and_pair_independence
        ; test_case
            "concurrent exclusive allocation"
            `Quick
            test_concurrent_allocations_are_exclusive
        ; test_case
            "keeper identity whitespace aliases rejected"
            `Quick
            test_keeper_id_surrounding_whitespace_is_rejected
        ; test_case
            "schema mismatch fails closed"
            `Quick
            test_schema_mismatch_fails_closed
        ; test_case
            "checksum tamper fails closed"
            `Quick
            test_checksum_tamper_fails_closed
        ; test_case
            "legacy generation ignored"
            `Quick
            test_legacy_generation_is_ignored
        ; test_case
            "read settlement warning fails closed"
            `Quick
            test_read_settlement_warning_fails_closed
        ; test_case
            "publication warning retains consumed nonce"
            `Quick
            test_publication_warning_retains_consumed_nonce
        ; test_case
            "published failure retains consumed nonce"
            `Quick
            test_published_failure_retains_consumed_nonce
        ; test_case
            "contention retry budget is finite"
            `Quick
            test_contention_retry_budget_is_finite
        ] )
    ]
;;
