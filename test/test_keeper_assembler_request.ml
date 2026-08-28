open Alcotest

module Request = Masc.Keeper_assembler_request
module Surface = Masc.Keeper_capability_surface
module Descriptor = Masc.Keeper_tool_descriptor

let empty_skill_snapshot =
  Skill_catalog_snapshot.config_unreadable ~detail:"fixture has no Skill sources"
;;

let empty_skills =
  Masc.Keeper_skill_catalog.of_snapshot empty_skill_snapshot |> fst
;;

let surface ?tool_groups () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  Surface.create
    ~tool_groups
    ~skill_names:None
    ~global_skill_catalog:empty_skills
    ~skill_inventory:(Masc.Keeper_skill_inventory.of_snapshot empty_skill_snapshot)
    ~task_skills:[]
;;

let capability surface name =
  Surface.tool_capabilities surface
  |> List.find_opt (fun (capability : Surface.tool_capability) ->
    Descriptor.keeper_model_names capability.descriptor
    |> List.exists (String.equal name))
  |> Option.get
;;

let reference surface name =
  Surface.ordinary_tool_reference (capability surface name)
;;

let request_json ?(objective = "Read current time") ?(execution = "inline") references =
  `Assoc
    [ "objective", `String objective
    ; "execution", `String execution
    ; ( "ordinary_tool_references"
      , `List (List.map Surface.ordinary_tool_reference_to_yojson references) )
    ]
;;

let parse surface json = Request.of_yojson ~capability_surface:surface json

let test_resolves_active_exact_reference_and_prompt_contract () =
  let surface = surface () in
  let reference = reference surface "keeper_time_now" in
  match parse surface (request_json [ reference ]) with
  | Error error -> fail (Yojson.Safe.to_string (Request.error_to_yojson error))
  | Ok request ->
    check int "one descriptor" 1 (List.length (Request.descriptors request));
    check
      string
      "surface digest"
      (Surface.digest surface)
      (Request.capability_surface_sha256 request);
    let variables =
      match Request.prompt_variables request with
      | Ok variables -> variables
      | Error error -> fail (Yojson.Safe.to_string (Request.error_to_yojson error))
    in
    check int "all managed variables" 6 (List.length variables);
    let descriptor_json = List.assoc "tool_descriptors_json" variables in
    let rows = Yojson.Safe.from_string descriptor_json |> Yojson.Safe.Util.to_list in
    check int "one prompt descriptor" 1 (List.length rows);
    check bool "exact schema included" true
      Yojson.Safe.Util.(List.hd rows |> member "input_schema" <> `Null);
    let output_schema =
      List.assoc "assembler_output_schema_json" variables |> Yojson.Safe.from_string
    in
    check int "closed output sum" 2
      Yojson.Safe.Util.(output_schema |> member "oneOf" |> to_list |> List.length)
;;

let test_rejects_duplicate_request_field () =
  let surface = surface () in
  let reference = reference surface "keeper_time_now" in
  let json =
    match request_json [ reference ] with
    | `Assoc fields -> `Assoc (("objective", `String "other") :: fields)
    | _ -> assert false
  in
  match parse surface json with
  | Error (Request.Duplicate_field "objective") -> ()
  | _ -> fail "duplicate field was not rejected"
;;

let test_rejects_duplicate_reference () =
  let surface = surface () in
  let reference = reference surface "keeper_time_now" in
  match parse surface (request_json [ reference; reference ]) with
  | Error (Request.Duplicate_tool_reference _) -> ()
  | _ -> fail "duplicate exact reference was not rejected"
;;

let test_rejects_mismatched_capability_identity () =
  let surface = surface () in
  let reference = reference surface "keeper_time_now" in
  let mismatched =
    match Surface.ordinary_tool_reference_to_yojson reference with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (field, value) ->
              if String.equal field "capability_id"
              then field, `String (String.make 64 'f')
              else field, value)
           fields)
    | _ -> assert false
  in
  let json =
    `Assoc
      [ "objective", `String "Read current time"
      ; "execution", `String "inline"
      ; "ordinary_tool_references", `List [ mismatched ]
      ]
  in
  match parse surface json with
  | Error (Request.Reference_resolution_failed _) -> ()
  | _ -> fail "mismatched capability identity was not rejected"
;;

let test_rejects_reference_outside_frozen_surface () =
  let full = surface () in
  let restricted = surface ~tool_groups:[ "board" ] () in
  let reference = reference full "Read" in
  match parse restricted (request_json [ reference ]) with
  | Error (Request.Referenced_tool_unavailable _) -> ()
  | _ -> fail "inactive Tool reference was not rejected"
;;

let test_async_requires_static_read_only () =
  let surface = surface () in
  let reference = reference surface "keeper_memory_write" in
  match parse surface (request_json ~execution:"async" [ reference ]) with
  | Error (Request.Async_tool_not_statically_read_only _) -> ()
  | _ -> fail "mutating async Tool reference was not rejected"
;;

let test_async_accepts_static_read_only () =
  let surface = surface () in
  let reference = reference surface "keeper_time_now" in
  match parse surface (request_json ~execution:"async" [ reference ]) with
  | Ok request -> check int "one descriptor" 1 (List.length (Request.descriptors request))
  | Error error -> fail (Yojson.Safe.to_string (Request.error_to_yojson error))
;;

let test_schema_embeds_reference_ssot () =
  let open Yojson.Safe.Util in
  let embedded =
    Request.input_schema
    |> member "properties"
    |> member "ordinary_tool_references"
    |> member "items"
  in
  check
    string
    "exact reference schema"
    (Yojson.Safe.to_string Surface.ordinary_tool_reference_schema)
    (Yojson.Safe.to_string embedded)
;;

let test_request_schema_pins_nonblank_unique_references () =
  let open Yojson.Safe.Util in
  let properties = Request.input_schema |> member "properties" in
  check string "objective nonblank pattern" "[^ \t\n\012\r]"
    (properties |> member "objective" |> member "pattern" |> to_string);
  check bool "reference array unique" true
    (properties |> member "ordinary_tool_references" |> member "uniqueItems" |> to_bool);
  let surface = surface () in
  let reference = reference surface "keeper_time_now" in
  let validate label objective expected_ok =
    let json = request_json ~objective [ reference ] in
    let pattern = properties |> member "objective" |> member "pattern" |> to_string in
    let schema_ok = Re.execp (Re.Pcre.regexp pattern) objective in
    let decoder_ok = Result.is_ok (parse surface json) in
    check bool (label ^ " schema") expected_ok schema_ok;
    check bool (label ^ " decoder") expected_ok decoder_ok
  in
  validate "multiline" "first line\nsecond line" true;
  validate "ASCII whitespace only" " \t\n\012\r" false;
  validate "non-breaking space" "\194\160" true
;;

let test_plan_schema_is_recursive_and_nonempty () =
  let open Yojson.Safe.Util in
  let schema = Masc.Keeper_tool_plan_request.input_schema in
  check int "nodes are nonempty" 1
    (schema |> member "properties" |> member "nodes" |> member "minItems" |> to_int);
  let template = schema |> member "$defs" |> member "template" in
  check int "four recursive template variants" 4
    (template |> member "oneOf" |> to_list |> List.length);
  let array_branch =
    template |> member "oneOf" |> to_list |> fun branches -> List.nth branches 3
  in
  check string "array items recurse" "#/$defs/template"
    (array_branch |> member "properties" |> member "items" |> member "items"
     |> member "$ref" |> to_string)
;;

let test_closed_output_envelope () =
  let surface = surface () in
  let reference = reference surface "keeper_time_now" in
  let request =
    match parse surface (request_json [ reference ]) with
    | Ok request -> request
    | Error error -> fail (Yojson.Safe.to_string (Request.error_to_yojson error))
  in
  (match Request.output_of_yojson ~request (`Assoc [ "kind", `String "cannot_assemble" ]) with
   | Ok Request.Cannot_assemble -> ()
   | _ -> fail "typed cannot_assemble was not decoded");
  (match
     Request.output_of_yojson
       ~request
       (`Assoc [ "kind", `String "cannot_assemble"; "reason", `String "guess" ])
   with
   | Error (Request.Output_unknown_field "reason") -> ()
   | _ -> fail "cannot_assemble accepted an invented sentinel field");
  let plan_json =
    `Assoc
      [ "kind", `String "plan"
      ; ( "plan",
          `Assoc
            [ ( "nodes",
                `List
                  [ `Assoc
                      [ "id", `String "clock"
                      ; "tool", `String "keeper_time_now"
                      ]
                  ] )
            ] )
      ]
  in
  match Request.output_of_yojson ~request plan_json with
  | Ok (Request.Plan _) -> ()
  | Error error -> fail (Yojson.Safe.to_string (Request.output_error_to_yojson error))
  | Ok Request.Cannot_assemble -> fail "plan became cannot_assemble"
;;

let test_plan_envelope_rejects_open_nested_template () =
  let surface = surface () in
  let reference = reference surface "keeper_time_now" in
  let request =
    match parse surface (request_json [ reference ]) with
    | Ok request -> request
    | Error error -> fail (Yojson.Safe.to_string (Request.error_to_yojson error))
  in
  let output =
    `Assoc
      [ "kind", `String "plan"
      ; ( "plan"
        , `Assoc
            [ ( "nodes"
              , `List
                  [ `Assoc
                      [ "id", `String "clock"
                      ; "tool", `String "keeper_time_now"
                      ; ( "input"
                        , `Assoc
                            [ "kind", `String "literal"
                            ; "value", `Assoc []
                            ; "invented", `Bool true
                            ] )
                      ]
                  ] )
            ] )
      ]
  in
  match Request.output_of_yojson ~request output with
  | Error
      (Request.Output_plan_rejected
         (Masc.Keeper_tool_plan_request.Node_template_error
            { error = Masc.Keeper_tool_plan_request.Template_unknown_field { field = "invented"; _ }
            ; _
            })) -> ()
  | _ -> fail "open nested template was accepted"
;;

let test_all_active_descriptors_have_total_prompt_projection () =
  let surface = surface () in
  let references =
    Surface.tool_capabilities surface
    |> List.filter_map (fun (capability : Surface.tool_capability) ->
      match capability.availability with
      | Surface.Active -> Some (Surface.ordinary_tool_reference capability)
      | _ -> None)
  in
  match parse surface (request_json references) with
  | Error error -> fail (Yojson.Safe.to_string (Request.error_to_yojson error))
  | Ok request ->
    (match Request.prompt_variables request with
     | Ok _ -> ()
     | Error error -> fail (Yojson.Safe.to_string (Request.error_to_yojson error)))
;;

let () =
  run
    "keeper assembler request"
    [ ( "contract"
      , [ test_case "active exact reference and prompt" `Quick
            test_resolves_active_exact_reference_and_prompt_contract
        ; test_case "duplicate request field" `Quick test_rejects_duplicate_request_field
        ; test_case "duplicate reference" `Quick test_rejects_duplicate_reference
        ; test_case "mismatched capability" `Quick
            test_rejects_mismatched_capability_identity
        ; test_case "outside frozen surface" `Quick
            test_rejects_reference_outside_frozen_surface
        ; test_case "async mutation" `Quick test_async_requires_static_read_only
        ; test_case "async read only" `Quick test_async_accepts_static_read_only
        ; test_case "reference schema SSOT" `Quick test_schema_embeds_reference_ssot
        ; test_case "request schema syntax parity" `Quick
            test_request_schema_pins_nonblank_unique_references
        ; test_case "recursive nonempty plan schema" `Quick
            test_plan_schema_is_recursive_and_nonempty
        ; test_case "closed output envelope" `Quick test_closed_output_envelope
        ; test_case "closed nested template" `Quick
            test_plan_envelope_rejects_open_nested_template
        ; test_case "all active prompt projections" `Quick
            test_all_active_descriptors_have_total_prompt_projection
        ] ) ]
;;
