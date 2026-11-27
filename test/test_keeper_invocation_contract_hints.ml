(** What the delegate tools take as [target], and what a refusal tells the
    caller to send instead.

    [target] is the receiving Keeper's name as a JSON string. A Keeper target
    has one kind, so the wire carries no field that names it (#38590). *)

module C = Masc.Keeper_invocation_contract

let message_of_target_json json =
  match C.target_of_json json with
  | Ok _ -> None
  | Error err -> Some (C.request_error_to_string err)

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let test_a_keeper_name_parses () =
  match C.target_of_json (`String "delta") with
  | Ok target ->
    Alcotest.(check string) "the name is the target" "delta"
      (C.target_name_of_target target)
  | Error err ->
    Alcotest.failf "expected a Keeper name to parse, got %s"
      (C.request_error_to_string err)

(* The two-field object is gone, not tolerated: a caller still sending it is
   told the shape to send, in the words the schema layer uses. *)
let test_an_object_is_refused_naming_the_string_shape () =
  List.iter
    (fun (label, json) ->
      match message_of_target_json json with
      | None -> Alcotest.failf "expected %s to be refused" label
      | Some msg ->
        Alcotest.(check bool) (label ^ ": names the field") true
          (contains ~needle:"\"target\"" msg);
        Alcotest.(check bool) (label ^ ": says the type is wrong") true
          (contains ~needle:"wrong type" msg);
        Alcotest.(check bool) (label ^ ": shows the shape to send") true
          (contains ~needle:{|"target": "reviewer"|} msg);
        Alcotest.(check bool) (label ^ ": names what arrived") true
          (contains ~needle:"got: object" msg))
    [ "kind and name", `Assoc [ "kind", `String "keeper"; "name", `String "delta" ]
    ; "name alone", `Assoc [ "name", `String "delta" ]
    ]

let test_a_mistyped_target_names_what_arrived () =
  match message_of_target_json (`Int 1) with
  | None -> Alcotest.fail "a non-string target must be refused"
  | Some msg ->
    Alcotest.(check bool) "names the expected type" true (contains ~needle:"string" msg);
    Alcotest.(check bool) "names what arrived" true (contains ~needle:"integer" msg)

let test_a_name_that_is_not_a_keeper_name_is_refused () =
  match C.target_of_json (`String "bad keeper!") with
  | Ok _ -> Alcotest.fail "a name that is not a Keeper name must be refused"
  | Error (C.Invalid_target reason) ->
    Alcotest.(check bool) "the reason is the Keeper name rule" true
      (contains ~needle:"keeper_name" reason)
  | Error err ->
    Alcotest.failf "refused for another reason: %s" (C.request_error_to_string err)

let test_an_absent_target_reads_as_missing () =
  match C.request_of_json (`Assoc [ "prompt", `String "hello" ]) with
  | Ok _ -> Alcotest.fail "a request without target must be refused"
  | Error err ->
    let msg = C.request_error_to_string err in
    Alcotest.(check bool) "names the field" true (contains ~needle:"delegate.target" msg);
    Alcotest.(check bool) "says it is missing" true (contains ~needle:"MISSING" msg);
    Alcotest.(check bool) "names the type to send" true
      (contains ~needle:"required: string" msg)

(* In the week measured for the capability change, all 29 delegate rejections
   were [capability], which the submitter cannot choose -- its enum has one member.
   22 said "task_assignment" and 7 said "claim_and_execute", both descriptions
   of the prompt rather than capabilities the contract offers. *)

let request_json ?capability () =
  `Assoc
    ((match capability with
      | None -> []
      | Some value -> [ "capability", `String value ])
     @ [ "target", `String "delta"
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
    [ "artifacts"; "prompt"; "target" ]
    props

let test_capability_is_still_accepted_on_the_wire () =
  match C.request_of_json (request_json ~capability:"invoke_turn" ()) with
  | Ok _ -> ()
  | Error err ->
    Alcotest.failf
      "an existing sender's capability must still parse, got %s"
      (C.request_error_to_string err)

let delegate_tool_names =
  [ "masc_keeper_delegate"
  ; "masc_keeper_delegate_cancel"
  ; "masc_keeper_delegate_list"
  ; "masc_keeper_delegate_status"
  ]

let schema_named name =
  match
    List.find_opt
      (fun (s : Masc_domain.tool_schema) -> String.equal s.name name)
      Masc.Keeper_schema.schemas
  with
  | Some s -> s.input_schema
  | None -> Alcotest.failf "%s must be in the keeper schema" name

let property name schema =
  match Yojson.Safe.Util.(schema |> member "properties" |> member name) with
  | `Null -> Alcotest.failf "the schema must declare %s" name
  | value -> value

(* The schema is what the model reads, so it is pinned with the decoder: a
   string here and an object there would refuse every call. *)
let test_every_delegate_schema_offers_target_as_a_string () =
  let check_target label target =
    Alcotest.(check string) (label ^ " target type") "string"
      Yojson.Safe.Util.(target |> member "type" |> to_string);
    Alcotest.(check bool) (label ^ " target has no fields") true
      (Yojson.Safe.Util.member "properties" target = `Null)
  in
  List.iter
    (fun name -> check_target name (property "target" (schema_named name)))
    delegate_tool_names;
  let element =
    Yojson.Safe.Util.member "items"
      (property "operations" (schema_named "masc_keeper_delegate_status_many"))
  in
  check_target "masc_keeper_delegate_status_many element" (property "target" element)

let () =
  Alcotest.run "keeper_invocation_contract_hints"
    [ ( "target_is_a_keeper_name"
      , [ Alcotest.test_case "a Keeper name parses" `Quick test_a_keeper_name_parses
        ; Alcotest.test_case "an object is refused naming the string shape" `Quick
            test_an_object_is_refused_naming_the_string_shape
        ; Alcotest.test_case "a mistyped target names what arrived" `Quick
            test_a_mistyped_target_names_what_arrived
        ; Alcotest.test_case "a name that is not a Keeper name is refused" `Quick
            test_a_name_that_is_not_a_keeper_name_is_refused
        ; Alcotest.test_case "an absent target reads as MISSING" `Quick
            test_an_absent_target_reads_as_missing
        ; Alcotest.test_case "every delegate schema offers target as a string" `Quick
            test_every_delegate_schema_offers_target_as_a_string
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
