open Alcotest

module Nonce = Masc.Keeper_lifecycle_nonce

open Test_keeper_lifecycle_nonce_support
open Test_keeper_lifecycle_nonce_admission

let require_ok = function
  | Ok value -> value
  | Error error -> fail (Nonce.error_to_string error)
;;

let target_nonce witness =
  Nonce.witness_target witness
  |> Nonce.identity_nonce
;;

let target_identity witness = Nonce.witness_target witness

let with_admission ~base_path ~keeper_id fn =
  let config = Masc.Workspace.default_config base_path in
  match
    Masc.Keeper_lifecycle_admission.Durable_transaction
    .with_durable_lifecycle_admission
      config
      ~keeper_name:keeper_id
      fn
  with
  | Admission_completed result -> result
  | Admission_completed_with_attention (result, _) -> result
  | Admission_blocked reason ->
    fail
      (Masc.Keeper_lifecycle_admission.Durable_transaction
       .blocked_reason_to_wire
         reason)
;;

let create_result ~base_path ~keeper_id ~owner_id =
  with_admission ~base_path ~keeper_id (fun permit ->
    Nonce.create permit ~base_path ~keeper_id ~owner_id ())
;;

let create ~base_path ~keeper_id ~owner_id =
  create_result ~base_path ~keeper_id ~owner_id |> require_ok
;;

let settled_target = function
  | Nonce.Settled_allocated witness -> Nonce.witness_target witness
  | Nonce.Settled_recovered (witness, _) -> Nonce.witness_target witness
;;

let replace_target ~base_path ~keeper_id ~source ~owner_id =
  with_admission ~base_path ~keeper_id (fun permit ->
    Nonce.replace_settled
      permit
      ~base_path
      ~keeper_id
      ~source
      ~owner_id
      ())
  |> require_ok
  |> settled_target
;;

let replace_settled ~base_path ~keeper_id ~source ~owner_id =
  with_admission ~base_path ~keeper_id (fun permit ->
    Nonce.replace_settled
      permit
      ~base_path
      ~keeper_id
      ~source
      ~owner_id
      ())
;;

let recover_exact ~base_path ~keeper_id ~source ~target =
  with_admission ~base_path ~keeper_id (fun permit ->
    Nonce.recover_exact
      permit
      ~base_path
      ~keeper_id
      ~source
      ~target
      ())
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
    replace_target
      ~base_path
      ~keeper_id:"keeper-a"
      ~source
      ~owner_id:"trace-b"
  in
  check int64 "replacement advances" 2L (Nonce.identity_nonce replaced);
  match
    replace_settled
      ~base_path
      ~keeper_id:"keeper-a"
      ~source
      ~owner_id:"trace-c"
  with
  | Ok (Nonce.Settled_recovered (witness, None)) ->
    check string
      "stale source recovers exact published owner"
      "trace-b"
      (Nonce.witness_target witness |> Nonce.identity_owner_id)
  | Error error -> failf "unexpected stale-source error: %s" (Nonce.error_to_string error)
  | Ok _ -> fail "stale source did not recover the exact published replacement"
;;

let test_recover_exact_does_not_allocate () =
  with_base "masc_lifecycle_witness_recover_" @@ fun base_path ->
  let created = create ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a" in
  let source = target_identity created in
  let target =
    replace_target
      ~base_path
      ~keeper_id:"keeper-a"
      ~source
      ~owner_id:"trace-b"
  in
  let recovered =
    recover_exact
      ~base_path
      ~keeper_id:"keeper-a"
      ~source:(Some source)
      ~target
    |> require_ok
  in
  check int64 "exact recovery retains nonce" 2L (target_nonce recovered);
  (match
     recover_exact
       ~base_path
       ~keeper_id:"keeper-a"
       ~source:(Some target)
       ~target:source
   with
   | Error Nonce.Authority_identity_mismatch -> ()
   | Error error ->
     failf "unexpected reverse recovery error: %s" (Nonce.error_to_string error)
   | Ok _ -> fail "reverse identity recovery was authorized");
  let next =
    replace_target
      ~base_path
      ~keeper_id:"keeper-a"
      ~source:target
      ~owner_id:"trace-c"
  in
  check int64 "recovery consumed no nonce" 3L (Nonce.identity_nonce next)
;;

let test_replace_settled_recovers_exact_published_target () =
  with_base "masc_lifecycle_witness_settled_" @@ fun base_path ->
  let created =
    create ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a"
  in
  let source = target_identity created in
  let published =
    replace_target
      ~base_path
      ~keeper_id:"keeper-a"
      ~source
      ~owner_id:"trace-b"
  in
  match
    replace_settled
      ~base_path
      ~keeper_id:"keeper-a"
      ~source
      ~owner_id:"trace-c"
  with
  | Ok (Nonce.Settled_recovered (witness, None)) ->
    let target = Nonce.witness_target witness in
    check string
      "settlement retains exact published owner"
      "trace-b"
      (Nonce.identity_owner_id target);
    check int64
      "settlement retains exact published nonce"
      (Nonce.identity_nonce published)
      (Nonce.identity_nonce target)
  | Ok (Nonce.Settled_recovered (_, Some _)) ->
    fail "stale-source exact recovery reported unrelated publication attention"
  | Ok (Nonce.Settled_allocated witness) ->
    failf "stale source allocated nonce %Ld" (target_nonce witness)
  | Error error ->
    failf "exact published replacement was not recovered: %s"
      (Nonce.error_to_string error)
;;

let test_publication_settlement_warning_is_recovered () =
  with_base "masc_lifecycle_witness_warning_" @@ fun base_path ->
  let source =
    create ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a"
    |> target_identity
  in
  match
    Nonce.For_testing.with_fault
      Nonce.For_testing.Publication_settlement_warning
      (fun () ->
        replace_settled
          ~base_path
          ~keeper_id:"keeper-a"
          ~source
          ~owner_id:"trace-b")
  with
  | Ok
      (Nonce.Settled_recovered
         (witness, Some (Nonce.Published_with_warnings _))) ->
    check int64 "warning target is settled" 2L (target_nonce witness)
  | Ok _ -> fail "publication warning did not return exact settled evidence"
  | Error error -> fail (Nonce.error_to_string error)
;;

let test_verified_publication_failure_is_recovered () =
  with_base "masc_lifecycle_witness_verified_failure_" @@ fun base_path ->
  let source =
    create ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a"
    |> target_identity
  in
  match
    Nonce.For_testing.with_fault
      Nonce.For_testing.Verified_publication_failure
      (fun () ->
        replace_settled
          ~base_path
          ~keeper_id:"keeper-a"
          ~source
          ~owner_id:"trace-b")
  with
  | Ok
      (Nonce.Settled_recovered
         (witness, Some (Nonce.Published_with_failure _))) ->
    check int64 "verified failure target is settled" 2L (target_nonce witness)
  | Ok _ -> fail "verified publication failure was not settled"
  | Error error -> fail (Nonce.error_to_string error)
;;

let test_indeterminate_publication_is_recovered () =
  with_base "masc_lifecycle_witness_indeterminate_" @@ fun base_path ->
  let source =
    create ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a"
    |> target_identity
  in
  match
    Nonce.For_testing.with_fault
      Nonce.For_testing.Publication_indeterminate
      (fun () ->
        replace_settled
          ~base_path
          ~keeper_id:"keeper-a"
          ~source
          ~owner_id:"trace-b")
  with
  | Ok
      (Nonce.Settled_recovered
         (witness, Some (Nonce.Publication_indeterminate _))) ->
    check int64 "indeterminate target is settled" 2L (target_nonce witness)
  | Ok _ -> fail "indeterminate publication was not settled"
  | Error error -> fail (Nonce.error_to_string error)
;;

let test_post_publication_cancellation_is_recovered () =
  with_base "masc_lifecycle_witness_cancelled_" @@ fun base_path ->
  let source =
    create ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-a"
    |> target_identity
  in
  match
    Nonce.For_testing.with_fault
      Nonce.For_testing.Cancellation_after_publication
      (fun () ->
        replace_settled
          ~base_path
          ~keeper_id:"keeper-a"
          ~source
          ~owner_id:"trace-b")
  with
  | Ok
      (Nonce.Settled_recovered
         (witness, Some (Nonce.Publication_indeterminate _))) ->
    check int64 "cancelled publication target is settled" 2L (target_nonce witness)
  | Ok _ -> fail "post-publication cancellation was not settled"
  | Error error -> fail (Nonce.error_to_string error)
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
  match create_result ~base_path ~keeper_id:"keeper-a" ~owner_id:"trace-b" with
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
        ; test_case
            "settled replace recovers exact published target"
            `Quick
            test_replace_settled_recovers_exact_published_target
        ; test_case
            "publication settlement warning is recovered"
            `Quick
            test_publication_settlement_warning_is_recovered
        ; test_case
            "verified publication failure is recovered"
            `Quick
            test_verified_publication_failure_is_recovered
        ; test_case
            "indeterminate publication is recovered"
            `Quick
            test_indeterminate_publication_is_recovered
        ; test_case
            "post-publication cancellation is recovered"
            `Quick
            test_post_publication_cancellation_is_recovered
        ; test_case "concurrent create is exclusive" `Quick test_concurrent_create_witnesses_are_exclusive
        ; test_case "shutdown floor bounds create" `Quick test_shutdown_floor_bounds_create
        ; test_case "invalid current evidence is generic" `Quick test_invalid_current_evidence_is_generic
        ; test_case
            "reentrant lease drains before admission release"
            `Quick
            test_reentrant_lease_drains_before_admission_release
        ] )
    ]
;;
