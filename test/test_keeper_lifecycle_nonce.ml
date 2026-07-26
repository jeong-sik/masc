open Alcotest

module Nonce = Masc.Keeper_lifecycle_nonce

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

let with_base prefix fn =
  let base_path = Filename.temp_file prefix ".tmp" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Unix.mkdir (Filename.concat base_path ".masc") 0o700;
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> fn base_path)
;;

let require_ok = function
  | Ok value -> value
  | Error error -> fail (Nonce.error_to_string error)
;;

let target_nonce witness =
  Nonce.witness_target witness
  |> Nonce.identity_nonce
;;

let target_identity witness = Nonce.witness_target witness

let create ~base_path ~keeper_id ~owner_id =
  Nonce.create ~base_path ~keeper_id ~owner_id () |> require_ok
;;

let authority_path ~base_path ~keeper_id =
  Filename.concat
    (Nonce.For_testing.root_path_for_base_path ~base_path)
    (Nonce.For_testing.authority_leaf ~keeper_id)
;;

let save_raw path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () ->
       output_string channel content;
       close_out channel);
  Unix.chmod path 0o600
;;

let test_first_no_evidence_is_one () =
  with_base "masc_lifecycle_witness_create_" @@ fun base_path ->
  let witness = create ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" in
  check int64 "first allocation" 1L (target_nonce witness);
  check string "keeper binding" "keeper-a" (Nonce.witness_keeper_id witness);
  check string "base path binding" base_path (Nonce.witness_base_path witness);
  check (option int64) "create has no source" None
    (Nonce.witness_source witness |> Option.map Nonce.identity_nonce)
;;

let test_replace_requires_exact_source () =
  with_base "masc_lifecycle_witness_replace_" @@ fun base_path ->
  let created = create ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" in
  let source = target_identity created in
  let replaced =
    Nonce.replace
      ~base_path
      ~keeper_id:"keeper-a"
      ~source
      ~owner_id:"trace-b"
      ()
    |> require_ok
  in
  check int64 "replacement advances" 2L (target_nonce replaced);
  match
    Nonce.replace
      ~base_path
      ~keeper_id:"keeper-a"
      ~source
      ~owner_id:"trace-c"
      ()
  with
  | Error Nonce.Authority_identity_mismatch -> ()
  | Error error -> failf "unexpected stale-source error: %s" (Nonce.error_to_string error)
  | Ok witness -> failf "stale source allocated nonce %Ld" (target_nonce witness)
;;

let test_recover_exact_does_not_allocate () =
  with_base "masc_lifecycle_witness_recover_" @@ fun base_path ->
  let created = create ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" in
  let source = target_identity created in
  let replaced =
    Nonce.replace
      ~base_path
      ~keeper_id:"keeper-a"
      ~source
      ~owner_id:"trace-b"
      ()
    |> require_ok
  in
  let target = target_identity replaced in
  let recovered =
    Nonce.recover_exact
      ~base_path
      ~keeper_id:"keeper-a"
      ~source:(Some source)
      ~target
      ()
    |> require_ok
  in
  check int64 "exact recovery retains nonce" 2L (target_nonce recovered);
  let next =
    Nonce.replace
      ~base_path
      ~keeper_id:"keeper-a"
      ~source:target
      ~owner_id:"trace-c"
      ()
    |> require_ok
  in
  check int64 "recovery consumed no nonce" 3L (target_nonce next)
;;

let test_concurrent_create_witnesses_are_exclusive () =
  with_base "masc_lifecycle_witness_concurrent_" @@ fun base_path ->
  let left = ref None in
  let right = ref None in
  Eio.Fiber.both
    (fun () ->
      left := Some (create ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a"))
    (fun () ->
      right := Some (create ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-b"));
  let nonce = function
    | Some witness -> target_nonce witness
    | None -> fail "concurrent create did not complete"
  in
  check
    (list int64)
    "exclusive nonces"
    [ 1L; 2L ]
    (List.sort Int64.compare [ nonce !left; nonce !right ])
;;

let test_shutdown_floor_bounds_create () =
  with_base "masc_lifecycle_witness_floor_" @@ fun base_path ->
  ignore
    (Masc.Keeper_shutdown_generation_floor.record_exact
       ~base_path
       ~keeper_id:"keeper-a"
       ~generation:7L
       ()
     |> function
     | Ok floor -> floor
     | Error error ->
       fail (Masc.Keeper_shutdown_generation_floor.error_to_string error));
  let witness = create ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" in
  check int64 "create exceeds shutdown floor" 8L (target_nonce witness)
;;

let test_invalid_current_evidence_is_generic () =
  with_base "masc_lifecycle_witness_invalid_" @@ fun base_path ->
  ignore (create ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a");
  save_raw
    (authority_path ~base_path ~keeper_id:"keeper-a")
    {|{"schema":"not-current","keeper_id":"keeper-a","allocated_to":"trace-a","nonce":1,"checksum_sha256":"0"}|};
  match Nonce.create ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-b" () with
  | Error (Nonce.Corrupt_current (Nonce.Invalid_current _)) -> ()
  | Error error -> failf "unexpected invalid-current error: %s" (Nonce.error_to_string error)
  | Ok witness -> failf "invalid evidence allocated nonce %Ld" (target_nonce witness)
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Nonce.For_testing.with_fd_backed_parent_opening @@ fun () ->
  Masc.Keeper_shutdown_generation_floor.For_testing.with_fd_backed_parent_opening
  @@ fun () ->
  run
    "keeper lifecycle nonce witnesses"
    [ ( "current schema"
      , [ test_case "first no-evidence allocation is one" `Quick test_first_no_evidence_is_one
        ; test_case "replace requires exact source" `Quick test_replace_requires_exact_source
        ; test_case "recover exact does not allocate" `Quick test_recover_exact_does_not_allocate
        ; test_case "concurrent create is exclusive" `Quick test_concurrent_create_witnesses_are_exclusive
        ; test_case "shutdown floor bounds create" `Quick test_shutdown_floor_bounds_create
        ; test_case "invalid current evidence is generic" `Quick test_invalid_current_evidence_is_generic
        ] )
    ]
;;
