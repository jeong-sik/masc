open Alcotest
open Capability_proof

let create
      ?(runtime_id = "ollama_cloud.deepseek-v4-flash")
      ?(model_id = Some "deepseek-v4-flash")
      ?(role = Autonomous_keeper)
      ?(capability = Autonomous_turn)
      ?(scenario = Nominal)
      ?(protocol = Agent_core_http)
      ?(build_commit = Some "6959248d23")
      ?(config_revision = Some "sha256:runtime-config")
      ()
  =
  Capability_proof.create
    ~runtime_id
    ~model_id
    ~role
    ~capability
    ~scenario
    ~protocol
    ~build_commit
    ~config_revision
;;

let id result =
  match result with
  | Ok case -> case |> case_id |> case_id_to_string
  | Error error -> failf "unexpected create error: %s" (create_error_to_string error)
;;

let test_identity_is_deterministic () =
  check string "same inputs have one identity" (id (create ())) (id (create ()))
;;

let test_absence_is_not_fabricated () =
  match create ~model_id:None ~build_commit:None ~config_revision:None () with
  | Error error -> failf "unexpected create error: %s" (create_error_to_string error)
  | Ok case ->
    check (option string) "model remains absent" None (model_id case);
    check (option string) "build remains absent" None (build_commit case);
    check (option string) "config revision remains absent" None (config_revision case)
;;

let test_present_and_absent_values_have_distinct_identity () =
  check bool "model absence changes identity" true (id (create ~model_id:None ()) <> id (create ()))
;;

let test_blank_values_are_rejected () =
  let cases =
    [ Blank_field Runtime_id, create ~runtime_id:" \t" ()
    ; Blank_field Model_id, create ~model_id:(Some "") ()
    ; Blank_field Build_commit, create ~build_commit:(Some " ") ()
    ; Blank_field Config_revision, create ~config_revision:(Some "\n") ()
    ]
  in
  List.iter
    (fun (expected, actual) ->
      match actual with
      | Error error ->
        check string "typed blank field" (create_error_to_string expected) (create_error_to_string error)
      | Ok case -> failf "blank field produced %s" (case |> case_id |> case_id_to_string))
    cases
;;

let test_closed_inventory_has_unique_case_ids () =
  let seen = Hashtbl.create 32768 in
  let collisions = ref [] in
  List.iter
    (fun role ->
      List.iter
        (fun capability ->
          List.iter
            (fun scenario ->
              List.iter
                (fun protocol ->
                  let case_id = id (create ~role ~capability ~scenario ~protocol ()) in
                  if Hashtbl.mem seen case_id then collisions := case_id :: !collisions;
                  Hashtbl.add seen case_id ())
                all_protocols)
            all_scenarios)
        all_capability_cases)
    all_proof_roles;
  check (list string) "no matrix identity collisions" [] (List.rev !collisions)
;;

let () =
  run
    "capability proof identity"
    [ ( "identity"
      , [ test_case "deterministic" `Quick test_identity_is_deterministic
        ; test_case "absence preserved" `Quick test_absence_is_not_fabricated
        ; test_case "absence is distinct" `Quick test_present_and_absent_values_have_distinct_identity
        ; test_case "blank rejected" `Quick test_blank_values_are_rejected
        ; test_case "closed inventory unique" `Quick test_closed_inventory_has_unique_case_ids
        ] )
    ]
;;
