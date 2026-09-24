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

(* The live route takes a screen-bearing source kind and an optional
   counter, and nothing else. Every other query is a 400. *)
let live_boundaries () =
  let reader = function
    | Ok (Lane_addon_sources.Msx_screen, since) -> Ok ("msx", since)
    | Ok (Lane_addon_sources.Dos_screen, since) -> Ok ("dos", since)
    | Error detail -> Error detail in
  let accepted = result (pair string (option int)) reject in
  check accepted "MSX without a counter" (Ok ("msx", None))
    (reader (Routes.decode_live_query ["source_kind", "msx_capture"]));
  check accepted "DOS with a counter, in any order" (Ok ("dos", Some 12))
    (reader (Routes.decode_live_query ["since", "12"; "source_kind", "dos_capture"]));
  check accepted "zero is a counter" (Ok ("dos", Some 0))
    (reader (Routes.decode_live_query ["source_kind", "dos_capture"; "since", "0"]));
  List.iter (fun (why, fields) ->
    check bool why true (Result.is_error (Routes.decode_live_query fields)))
    [ "no kind", [];
      "a file has no screen", ["source_kind", "snapshot_file"];
      "a Lane output has no screen", ["source_kind", "lane_output"];
      "a browser document has no screen", ["source_kind", "browser_document"];
      "an unknown kind", ["source_kind", "vic20_capture"];
      "two kinds", ["source_kind", "msx_capture"; "source_kind", "dos_capture"];
      "an instance is not part of the route", ["source_kind", "dos_capture"; "instance_id", "i"];
      "a blank counter", ["source_kind", "dos_capture"; "since", ""];
      "a negative counter", ["source_kind", "dos_capture"; "since", "-1"];
      "a hex counter", ["source_kind", "dos_capture"; "since", "0x10"];
      "an underscored counter", ["source_kind", "dos_capture"; "since", "1_0"];
      "a fractional counter", ["source_kind", "dos_capture"; "since", "1.5"];
      "a word", ["source_kind", "dos_capture"; "since", "latest"] ]

(* The route is wrapped in [with_read_auth]; that wrapper answers from
   [authorize_read_request], and only [is_public_read_path] could bypass it. *)
let live_requires_authentication () =
  let path = "/api/v1/lane-addons/live?source_kind=dos_capture" in
  check bool "live is not on the public-read allowlist" false
    (Server_auth.is_public_read_path "/api/v1/lane-addons/live");
  let base_path = Filename.temp_file "lane-live-auth-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect ~finally:(fun () -> Unix.rmdir base_path) (fun () ->
    let anonymous = Httpun.Request.create `GET path in
    match Server_auth.authorize_read_request ~base_path anonymous with
    | Error (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized _)) -> ()
    | Error other -> failf "refused for another reason: %s" (Masc_domain.masc_error_to_string other)
    | Ok () -> fail "a request without a credential was admitted")

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
        test_case "query windows and duplicate identities" `Quick query_boundaries;
        test_case "live takes a screen kind and a decimal counter" `Quick live_boundaries;
        test_case "live requires authentication" `Quick live_requires_authentication] ]
