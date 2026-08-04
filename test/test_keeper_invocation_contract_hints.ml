(** An undeclared-field rejection names the fields that are accepted.

    Live tool-call logs show the cost of the previous message. masc_keeper_delegate
    failed 43 times out of 171, and the failures are field-name guesses:
    target.agent, then target.keeper_name, then target.keeper, one per call,
    against an allowed list of [kind; name]. The rejection said only
    "no undeclared field", so each attempt was a fresh guess. *)

module C = Masc.Keeper_invocation_contract

let message_of_target_json json =
  match C.target_of_json json with
  | Ok _ -> None
  | Error err -> Some (C.request_error_to_string err)

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let test_undeclared_field_names_the_accepted_set () =
  (* The exact shape taskmaster sent. *)
  let json = `Assoc [ "agent", `String "analyst" ] in
  match message_of_target_json json with
  | None -> Alcotest.fail "expected target.agent to be rejected"
  | Some msg ->
    Alcotest.(check bool) "names the offending field" true
      (contains ~needle:"target.agent" msg);
    Alcotest.(check bool) "names the accepted fields" true
      (contains ~needle:"accepted: kind, name" msg)

let test_other_guessed_names_get_the_same_hint () =
  List.iter
    (fun field ->
      let json = `Assoc [ field, `String "analyst" ] in
      match message_of_target_json json with
      | None -> Alcotest.failf "expected target.%s to be rejected" field
      | Some msg ->
        Alcotest.(check bool)
          (Printf.sprintf "target.%s hint lists accepted fields" field)
          true
          (contains ~needle:"accepted: kind, name" msg))
    [ "keeper_name"; "keeper" ]

let test_valid_target_still_parses () =
  let json = `Assoc [ "kind", `String "keeper"; "name", `String "analyst" ] in
  match C.target_of_json json with
  | Ok _ -> ()
  | Error err ->
    Alcotest.failf "expected a kind/name target to parse, got %s"
      (C.request_error_to_string err)

let () =
  Alcotest.run "keeper_invocation_contract_hints"
    [ ( "undeclared_field_hint"
      , [ Alcotest.test_case "names the accepted set" `Quick
            test_undeclared_field_names_the_accepted_set
        ; Alcotest.test_case "same hint for other guesses" `Quick
            test_other_guessed_names_get_the_same_hint
        ; Alcotest.test_case "a valid target still parses" `Quick
            test_valid_target_still_parses
        ] )
    ]
