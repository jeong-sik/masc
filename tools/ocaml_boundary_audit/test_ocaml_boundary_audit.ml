open Ocaml_boundary_audit

let category = Alcotest.testable (fun formatter value ->
  Format.pp_print_string formatter (category_to_string value)) ( = )
;;

let test_resolved_partial_extraction () =
  List.iter
    (fun callee ->
       Alcotest.(check (option category))
         callee
         (Some Partial_extraction)
         (category_for_resolved_callee callee))
    [ "Stdlib!.Option.get"
    ; "Stdlib.Option.get"
    ; "Stdlib!.Result.get_ok"
    ];
  Alcotest.(check (option category))
    "local module with the same final name is not Stdlib"
    None
    (category_for_resolved_callee "Example.Option.get")
;;

let test_resolved_failure_erasure () =
  List.iter
    (fun callee ->
       Alcotest.(check (option category))
         callee
         (Some Failure_erasure)
         (category_for_resolved_callee callee))
    [ "Stdlib!.Result.to_option"
    ; "Result.to_option"
    ; "Agent_core__Parse_outcome.to_option"
    ]
;;

let test_resolved_effects () =
  List.iter
    (fun callee -> Alcotest.(check bool) callee true (effectful_resolved_callee callee))
    [ "Stdlib!.Sys.getenv_opt"
    ; "Unix!.gettimeofday"
    ; "Unix!.putenv"
    ; "Eio!.Time.sleep"
    ; "Fs_compat.read_file"
    ; "Masc_log__Log.Keeper.info"
    ];
  Alcotest.(check bool)
    "gmtime is a pure conversion of supplied data"
    false
    (effectful_resolved_callee "Unix!.gmtime")
;;

let site ?(scope = "decode") ?(callee = "Stdlib.Option.get") category =
  { category
  ; path = "lib/sample.ml"
  ; scope
  ; callee
  ; line = 10
  ; column = 2
  }
;;

let test_downward_comparison () =
  let baseline =
    entries_of_sites [ site Partial_extraction; site Partial_extraction ]
  in
  let reduced = entries_of_sites [ site Partial_extraction ] in
  let increased =
    entries_of_sites
      [ site Partial_extraction; site Partial_extraction; site Partial_extraction ]
  in
  let reduction = compare ~baseline ~current:reduced in
  let increase = compare ~baseline ~current:increased in
  Alcotest.(check int) "one reduced bucket" 1 (List.length reduction.reductions);
  Alcotest.(check int) "no increase" 0 (List.length reduction.increases);
  Alcotest.(check int) "one increased bucket" 1 (List.length increase.increases)
;;

let test_baseline_round_trip () =
  let path = Filename.temp_file "ocaml-boundary-test-" ".tsv" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
       let expected =
         entries_of_sites
           [ site Partial_extraction
           ; site Failure_erasure ~callee:"Stdlib.Result.to_option"
           ]
       in
       (match write_baseline path expected with
        | Ok () -> ()
        | Error message -> Alcotest.fail message);
       match read_baseline path with
       | Error message -> Alcotest.fail message
       | Ok actual -> Alcotest.(check bool) "round trip" true (expected = actual))
;;

let test_pure_registry_rejects_escape () =
  let root = Filename.temp_file "ocaml-boundary-root-" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  let registry = Filename.concat root "pure.txt" in
  let channel = open_out registry in
  output_string channel "../outside.ml\n";
  close_out channel;
  Fun.protect
    ~finally:(fun () ->
      Sys.remove registry;
      Unix.rmdir root)
    (fun () ->
       match read_pure_modules ~root registry with
       | Ok _ -> Alcotest.fail "registry path escape was accepted"
       | Error _ -> ())
;;

let () =
  Alcotest.run
    "ocaml-boundary-audit"
    [ ( "typed path classification"
      , [ Alcotest.test_case
            "partial extraction"
            `Quick
            test_resolved_partial_extraction
        ; Alcotest.test_case "failure erasure" `Quick test_resolved_failure_erasure
        ; Alcotest.test_case "effect APIs" `Quick test_resolved_effects
        ] )
    ; ( "ratchet"
      , [ Alcotest.test_case "downward only" `Quick test_downward_comparison
        ; Alcotest.test_case "baseline round trip" `Quick test_baseline_round_trip
        ; Alcotest.test_case
            "pure registry rejects path escape"
            `Quick
            test_pure_registry_rejects_escape
        ] )
    ]
;;
