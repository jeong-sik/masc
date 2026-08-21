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
  (* The exact shape fixture-keeper sent. *)
  let json = `Assoc [ "agent", `String "delta" ] in
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
      let json = `Assoc [ field, `String "delta" ] in
      match message_of_target_json json with
      | None -> Alcotest.failf "expected target.%s to be rejected" field
      | Some msg ->
        Alcotest.(check bool)
          (Printf.sprintf "target.%s hint lists accepted fields" field)
          true
          (contains ~needle:"accepted: kind, name" msg))
    [ "keeper_name"; "keeper" ]

let test_valid_target_still_parses () =
  let json = `Assoc [ "kind", `String "keeper"; "name", `String "delta" ] in
  match C.target_of_json json with
  | Ok _ -> ()
  | Error err ->
    Alcotest.failf "expected a kind/name target to parse, got %s"
      (C.request_error_to_string err)

(* The field-name hint above closed the target guesses: in the week measured for
   this change, 0 of 29 delegate rejections were target shape. All 29 were
   [capability], which the submitter cannot choose -- its enum has one member.
   22 said "task_assignment" and 7 said "claim_and_execute", both descriptions
   of the prompt rather than capabilities the contract offers. *)

let request_json ?capability () =
  `Assoc
    ((match capability with
      | None -> []
      | Some value -> [ "capability", `String value ])
     @ [ "target", `Assoc [ "kind", `String "keeper"; "name", `String "delta" ]
       ; "prompt", `String "Claim and work on task-154."
       ])

let test_omitted_capability_is_accepted () =
  match C.request_of_json (request_json ()) with
  | Ok _ -> ()
  | Error err ->
    Alcotest.failf "expected a request without capability to parse, got %s"
      (C.request_error_to_string err)

let test_stated_capability_still_parses () =
  match C.request_of_json (request_json ~capability:"invoke_turn" ()) with
  | Ok _ -> ()
  | Error err ->
    Alcotest.failf "expected capability=invoke_turn to parse, got %s"
      (C.request_error_to_string err)

(* Omitting is not the same as widening: the two values actually sent are still
   refused, and the refusal still names what the field accepts. *)
let test_the_invented_capabilities_are_still_refused () =
  List.iter
    (fun value ->
      match C.request_of_json (request_json ~capability:value ()) with
      | Ok _ -> Alcotest.failf "expected capability=%s to be refused" value
      | Error err ->
        let msg = C.request_error_to_string err in
        Alcotest.(check bool)
          (Printf.sprintf "%s rejection names the field" value)
          true
          (contains ~needle:"delegate.capability" msg);
        Alcotest.(check bool)
          (Printf.sprintf "%s rejection names the accepted value" value)
          true
          (contains ~needle:"invoke_turn" msg))
    [ "task_assignment"; "claim_and_execute" ]

(* #27434 made [capability] optional and that was not enough: measured across
   the week, all 64 delegate calls sent the field explicitly and none omitted
   it, so the 29 rejections were unchanged. A field the model can see is a field
   it fills in. The schema stops offering it; the decoder still takes it, so the
   dashboard and operator paths that send it keep working. Both halves are
   pinned here because either one alone is a regression. *)

let delegate_schema () =
  match
    List.find_opt
      (fun (s : Masc_domain.tool_schema) -> String.equal s.name "masc_keeper_delegate")
      Masc.Keeper_schema.schemas
  with
  | Some s -> s
  | None -> Alcotest.fail "masc_keeper_delegate must be in the keeper schema"

let advertised_properties () =
  match (delegate_schema ()).input_schema with
  | `Assoc fields ->
    (match List.assoc_opt "properties" fields with
     | Some (`Assoc props) -> List.map fst props
     | _ -> Alcotest.fail "input_schema must declare an object of properties")
  | _ -> Alcotest.fail "input_schema must be an object"

let test_capability_is_not_advertised () =
  let props = List.sort compare (advertised_properties ()) in
  Alcotest.(check (list string))
    "the submitter is offered only what it can decide"
    [ "prompt"; "target" ]
    props

let test_capability_is_still_accepted_on_the_wire () =
  match C.request_of_json (request_json ~capability:"invoke_turn" ()) with
  | Ok _ -> ()
  | Error err ->
    Alcotest.failf
      "an existing sender's capability must still parse, got %s"
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
    ; ( "single_value_capability"
      , [ Alcotest.test_case "omitted capability is accepted" `Quick
            test_omitted_capability_is_accepted
        ; Alcotest.test_case "stated capability still parses" `Quick
            test_stated_capability_still_parses
        ; Alcotest.test_case "the invented values are still refused" `Quick
            test_the_invented_capabilities_are_still_refused
        ; Alcotest.test_case "capability is not advertised" `Quick
            test_capability_is_not_advertised
        ; Alcotest.test_case "capability is still accepted on the wire" `Quick
            test_capability_is_still_accepted_on_the_wire
        ] )
    ]
