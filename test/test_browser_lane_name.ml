open Alcotest
module Lane_name = Browser_lane.Lane_name

let lane = testable (fun fmt lane -> Format.pp_print_string fmt (Lane_name.to_wire lane)) ( = )

let test_round_trip () =
  List.iter (fun name -> check (option lane) (Lane_name.to_wire name) (Some name)
    (Lane_name.of_wire (Lane_name.to_wire name))) Lane_name.all;
  check string "error text lists every lane" "live or automation or stagehand" Lane_name.expected

let test_rejects_non_names () =
  List.iter (fun raw -> check (option lane) (Printf.sprintf "%S" raw) None (Lane_name.of_wire raw))
    [ ""; "Live"; " live"; "automation "; "chromium" ]

let lane_param (schema : Masc_domain.tool_schema) =
  Yojson.Safe.Util.(schema.input_schema |> member "properties" |> member "lane")

let lane_enum schema = Yojson.Safe.Util.(lane_param schema |> member "enum" |> to_list |> List.map to_string)
let lane_default schema = Yojson.Safe.Util.(lane_param schema |> member "default" |> to_string)

let decode_all tool names =
  List.map (fun raw -> match Lane_name.of_wire raw with
    | Some name -> name
    | None -> failf "%s declares lane %S, which no reader decodes" tool raw) names

let sorted lanes = List.sort compare lanes

(* A tool that offers every lane must list exactly the names the readers
   decode, so a lane added in code shows up here until its tools declare it.
   The declared default is the lane a missing [lane] means in code: live for
   the read tools ([route_of], [Browser_surface.parse_request]) and
   automation for BrowserAct. *)
let test_tool_enums () =
  List.iter (fun (tool, schema) ->
    check (list lane) (tool ^ " offers every lane") (sorted Lane_name.all)
      (sorted (decode_all tool (lane_enum schema)));
    check (list lane) (tool ^ " defaults to live") [ Lane_name.Live ] (decode_all tool [ lane_default schema ]))
    [ "masc_browser_tabs", Tool_schemas_misc_toml.browser_tabs;
      "masc_browser_read", Tool_schemas_misc_toml.browser_read;
      "masc_browser_interact", Tool_schemas_misc_toml.browser_interact ];
  let act = Tool_schemas_misc_toml.browser_act in
  check (list lane) "masc_browser_act offers automation only" [ Lane_name.Automation ]
    (decode_all "masc_browser_act" (lane_enum act));
  check (list lane) "masc_browser_act defaults to automation" [ Lane_name.Automation ]
    (decode_all "masc_browser_act" [ lane_default act ]);
  (* Sessions and navigation belong to the lanes the server owns. *)
  List.iter (fun (tool, schema) ->
    check (list lane) (tool ^ " offers the server's lanes") (sorted [ Lane_name.Automation; Lane_name.Stagehand ])
      (sorted (decode_all tool (lane_enum schema)));
    check (list lane) (tool ^ " defaults to automation") [ Lane_name.Automation ] (decode_all tool [ lane_default schema ]))
    [ "masc_browser_session", Tool_schemas_misc_toml.browser_session;
      "masc_browser_goto", Tool_schemas_misc_toml.browser_goto ]

let () =
  run "browser_lane_name" [
    "wire", [
      test_case "every lane round-trips" `Quick test_round_trip;
      test_case "a non-name is refused" `Quick test_rejects_non_names;
    ];
    "tool schemas", [ test_case "lane enums decode" `Quick test_tool_enums ];
  ]
