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

(* The server lanes: live is refused with whose browser it is, a non-name
   with the names that serve, and the two server lanes are read. *)
let test_server_lane () =
  let server = function
    | Ok lane -> Lane_name.to_wire (Browser_lane.server_lane_name lane)
    | Error detail -> "refused: " ^ detail
  in
  check string "automation" "automation" (server (Browser_lane.parse_server_lane "automation"));
  check string "stagehand" "stagehand" (server (Browser_lane.parse_server_lane "stagehand"));
  check string "live names its owner" ("refused: the live browser belongs to the operator; " ^ Browser_lane.server_lane_refused)
    (server (Browser_lane.parse_server_lane "live"));
  check string "a non-name lists the server lanes" ("refused: " ^ Browser_lane.server_lane_refused)
    (server (Browser_lane.parse_server_lane "chromium"))

let lane_param (schema : Masc_domain.tool_schema) =
  Yojson.Safe.Util.(schema.input_schema |> member "properties" |> member "lane")

let lane_enum schema = Yojson.Safe.Util.(lane_param schema |> member "enum" |> to_list |> List.map to_string)
let lane_default schema = Yojson.Safe.Util.(lane_param schema |> member "default" |> to_string)

let decode_all tool names =
  List.map (fun raw -> match Lane_name.of_wire raw with
    | Some name -> name
    | None -> failf "%s declares lane %S, which no reader decodes" tool raw) names

let sorted lanes = List.sort compare lanes

(* A tool offers a lane exactly when that lane's backend serves the verbs the
   tool issues with its defaults, so a schema cannot advertise a lane whose
   backend refuses the call, and a lane added in code shows up here until the
   tools it serves declare it. *)
let serving verbs = List.filter (fun lane -> List.for_all (Browser_lane.verb_allowed lane) verbs) Lane_name.all

let tool_verbs = Browser_lane.[
  "masc_browser_tabs", Tool_schemas_misc_toml.browser_tabs, [ Tabs_list ];
  "masc_browser_read", Tool_schemas_misc_toml.browser_read, [ Page_read { tab_id = None; max_chars = None } ];
  "masc_browser_interact", Tool_schemas_misc_toml.browser_interact,
    [ Page_interact { tab_id = 1; expected_url = None; action = Scroll { x = 0; y = 1 } } ];
  "masc_browser_session", Tool_schemas_misc_toml.browser_session,
    [ Session_open { headless = None }; Session_close; Session_status ];
  "masc_browser_goto", Tool_schemas_misc_toml.browser_goto,
    [ Page_goto { url = "https://example.org/"; tab_id = None } ];
]

(* The declared default is the lane a missing [lane] means in code: live for
   the reads ([Browser_surface.parse_request]), automation for the tools that
   only the server's lanes serve ([issue_on_server_lane], [route_of] for
   BrowserAct). *)
let declared_default = [
  "masc_browser_tabs", Lane_name.Live;
  "masc_browser_read", Lane_name.Live;
  "masc_browser_interact", Lane_name.Live;
  "masc_browser_session", Lane_name.Automation;
  "masc_browser_goto", Lane_name.Automation;
]

let test_tool_enums () =
  List.iter (fun (tool, schema, verbs) ->
    check (list lane) (tool ^ " offers the lanes that serve it") (sorted (serving verbs))
      (sorted (decode_all tool (lane_enum schema)));
    check (list lane) (tool ^ " default") [ List.assoc tool declared_default ] (decode_all tool [ lane_default schema ]))
    tool_verbs;
  let act = Tool_schemas_misc_toml.browser_act in
  check (list lane) "masc_browser_act offers automation only" [ Lane_name.Automation ]
    (decode_all "masc_browser_act" (lane_enum act));
  check (list lane) "masc_browser_act defaults to automation" [ Lane_name.Automation ]
    (decode_all "masc_browser_act" [ lane_default act ])

let () =
  run "browser_lane_name" [
    "wire", [
      test_case "every lane round-trips" `Quick test_round_trip;
      test_case "a non-name is refused" `Quick test_rejects_non_names;
      test_case "server lanes refuse live with its owner" `Quick test_server_lane;
    ];
    "tool schemas", [ test_case "lane enums follow the backends" `Quick test_tool_enums ];
  ]
