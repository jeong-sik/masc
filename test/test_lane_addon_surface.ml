(** Boundary tests for optional Lane Add-ons: the same operations are reachable
    by operators and Keepers, while input identity is never repaired by guessing. *)
open Alcotest
open Masc

module Routes = Server_routes_http_routes_lane_addons

let tool_names =
  [ "masc_lane_attach"; "masc_lane_inspect"; "masc_lane_observe";
    "masc_lane_declaration_read"; "masc_lane_declaration_save"; "masc_lane_updates";
    "masc_lane_slice"; "masc_lane_detach"; "masc_lane_evidence" ]

let reachable_operations () =
  let visible = Keeper_tool_descriptor.model_visible_schemas () in
  List.iter (fun name ->
    check bool (name ^ " external discovery") true (Tool_catalog.is_public_mcp name);
    check bool (name ^ " explicit permission") true (Option.is_some (Tool_catalog.registered_metadata name));
    check bool (name ^ " Keeper schema") true
      (List.exists (fun (schema : Masc_domain.tool_schema) -> schema.name = name) visible);
    match Tool_schemas_misc.misc_operation_of_tool_name name with
    | None -> fail (name ^ " has no typed operation")
    | Some operation ->
        match Tool_schemas_misc.misc_registered_schema operation with
        | None -> fail (name ^ " has no registered MCP schema")
        | Some schema -> check string "same schema name" name schema.name) tool_names

let readonly_parameters_preserve_identity () =
  let expected_url = "https://service.test:8443/app?slot=preview" in
  match Routes.decode_body
    (Yojson.Safe.to_string (`Assoc ["binding", `Assoc ["url", `String expected_url]])) with
  | Error detail -> fail detail
  | Ok (`Assoc ["binding", `Assoc ["url", `String actual]]) ->
      check string "exact source URL" expected_url actual
  | Ok _ -> fail "request object changed"

let query_boundaries () =
  let accepted = Routes.decode_slice_query ["run_id", "run/alpha"; "lane_id", "foreign.layer"; "since", "0"; "until", "2.5"] in
  check bool "epoch zero is a real boundary" true
    (match accepted with
     | Ok (`Assoc fields) -> List.assoc_opt "since" fields = Some (`Float 0.)
     | _ -> false);
  List.iter (fun fields -> check bool "invalid query rejected" true
    (Result.is_error (Routes.decode_slice_query fields)))
    [["since", "nan"]; ["until", "infinity"]; ["since", "2"; "until", "1"];
     ["lane_id", "a"; "lane_id", "b"]; ["run_id", ""]; ["guessed_target", "production"]];
  check bool "duplicate inspect target rejected" true
    (Result.is_error (Routes.decode_inspect_query ["instance_id", "first"; "instance_id", "second"]));
  check bool "duplicate body identity rejected" true
    (Result.is_error (Routes.decode_body {|{"instance_id":"first","instance_id":"second"}|}));
  check bool "non-object body rejected" true (Result.is_error (Routes.decode_body "[]"))

let subscription_items_keep_strict_schema () =
  let schema = match Tool_schemas_misc.misc_registered_schema Tool_schemas_misc.Misc_lane_updates with
    | Some schema -> schema | None -> fail "missing subscription schema" in
  let member = Yojson.Safe.Util.member in
  let items = schema.input_schema |> member "properties" |> member "subscriptions" |> member "items" in
  check bool "subscription item rejects undeclared properties" true
    (member "additionalProperties" items=`Bool false);
  check (list string) "every subscription identity field remains required"
    ["installation_id";"keeper_name";"output_id";"run_id"]
    (member "required" items |> Yojson.Safe.Util.to_list
     |> List.map Yojson.Safe.Util.to_string |> List.sort String.compare);
  List.iter (fun key ->
    let property=items |> member "properties" |> member key in
    check bool "identity fields remain nonempty strings" true
      (member "type" property=`String "string" && member "minLength" property=`Int 1))
    ["keeper_name";"run_id";"installation_id";"output_id"]

let () =
  run "Lane Add-on surfaces"
    [ "installed contract", [test_case "operator and Keeper discovery agree" `Quick reachable_operations;
        test_case "subscription TOML emits strict nested item schema" `Quick subscription_items_keep_strict_schema];
      "request boundaries", [test_case "source identity remains exact" `Quick readonly_parameters_preserve_identity;
        test_case "query windows and duplicate identities" `Quick query_boundaries] ]
