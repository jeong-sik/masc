open Alcotest
module Lane_name = Browser_lane.Lane_name

let lane = testable (fun fmt lane -> Format.pp_print_string fmt (Lane_name.to_wire lane)) ( = )

let test_round_trip () =
  List.iter (fun name -> check (option lane) (Lane_name.to_wire name) (Some name)
    (Lane_name.of_wire (Lane_name.to_wire name))) Lane_name.all;
  check string "error text lists every lane" "live" Lane_name.expected

let test_rejects_non_names () =
  List.iter (fun raw -> check (option lane) (Printf.sprintf "%S" raw) None (Lane_name.of_wire raw))
    [ ""; "Live"; " live"; "live "; "chromium" ]

let lane_param (schema : Masc_domain.tool_schema) =
  Yojson.Safe.Util.(schema.input_schema |> member "properties" |> member "lane")

let lane_enum schema = Yojson.Safe.Util.(lane_param schema |> member "enum" |> to_list |> List.map to_string)
let lane_default schema = Yojson.Safe.Util.(lane_param schema |> member "default")

let decode_all tool names =
  List.map (fun raw -> match Lane_name.of_wire raw with
    | Some name -> name
    | None -> failf "%s declares lane %S, which no reader decodes" tool raw) names

let sorted lanes = List.sort compare lanes

(* Every lane serves every browser verb, so each browser tool that takes a
   lane offers every lane, and a lane added in code shows up here until the
   tools declare it. BrowserInteract and BrowserGoto act on a named client and
   take no lane. *)
let browser_tools = [
  "masc_browser_tabs", Tool_schemas_misc_toml.browser_tabs;
  "masc_browser_read", Tool_schemas_misc_toml.browser_read;
  "masc_browser_act", Tool_schemas_misc_toml.browser_act;
  "masc_browser_session", Tool_schemas_misc_toml.browser_session;
]

(* Omission now selects from observed browser state. Schemas must leave it
   absent so callers do not accidentally pin a backend before discovery. *)
let test_tool_enums () =
  List.iter (fun (tool, schema) ->
    check (list lane) (tool ^ " offers every lane") (sorted Lane_name.all)
      (sorted (decode_all tool (lane_enum schema)));
    check bool (tool ^ " leaves automatic selection available") true (lane_default schema = `Null))
    browser_tools

let () =
  run "browser_lane_name" [
    "wire", [
      test_case "every lane round-trips" `Quick test_round_trip;
      test_case "a non-name is refused" `Quick test_rejects_non_names;
    ];
    "tool schemas", [ test_case "browser tools offer every lane" `Quick test_tool_enums ];
  ]
