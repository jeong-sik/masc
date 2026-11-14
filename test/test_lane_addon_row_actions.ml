(* RFC lane-row-offers-actions-filled-from-its-own-fields L1: the presentation
   [actions] grammar, the row value reader, the manifest action tool check and
   the host verdict. *)
open Alcotest
module P = Masc.Lane_addon_presentation
module R = Masc.Lane_addon_row_action

let json = Yojson.Safe.from_string
let parse text = P.of_json (json text)
let refused label text = check bool label true (Result.is_error (parse text))

let dispute_action = {|{"lane_id":"quiz/questions","label":"Dispute this grade",
  "fixed":{"kind":"dispute"},
  "from_row":{"ask_id":["dispute","ask_id"],"question_id":["dispute","question_id"]}}|}

let action () = match parse (Printf.sprintf {|{"actions":[%s]}|} dispute_action) with
  | Ok { P.actions = [ action ]; _ } -> action
  | Ok _ -> fail "expected exactly one action"
  | Error detail -> fail detail

(* A package without row actions writes the same presentation it wrote before
   [actions] existed, so its declaration revision does not move. *)
let presentation_without_actions_keeps_its_json () =
  let before = {|{"description":"Quiz","readings":[{"lane_id":"quiz/questions","path":["grading"],"label":"Grading","unit":null,"format":"text"}]}|} in
  let presentation = match parse before with Ok value -> value | Error detail -> fail detail in
  check bool "no actions" true (presentation.P.actions = []);
  check bool "same JSON as before actions" true (Yojson.Safe.equal (json before) (P.to_json presentation));
  check bool "empty presentation unchanged" true
    (Yojson.Safe.equal (json {|{"description":null,"readings":[]}|}) (P.to_json P.empty));
  check bool "an explicit empty list writes nothing" true
    (match parse {|{"actions":[]}|} with
     | Ok value -> Yojson.Safe.equal (json {|{"description":null,"readings":[]}|}) (P.to_json value)
     | Error _ -> false)

let actions_round_trip () =
  let text = Printf.sprintf {|{"description":null,"readings":[],"actions":[%s]}|} dispute_action in
  match parse text with
  | Error detail -> fail detail
  | Ok value -> check bool "declared actions are written back" true
      (Yojson.Safe.equal (json text) (P.to_json value))

let parser_refuses_invalid_actions () =
  let with_action body = Printf.sprintf {|{"actions":[%s]}|} body in
  refused "unknown key" (with_action {|{"lane_id":"l","label":"x","fixed":{},"from_row":{"a":["a"]},"extra":1}|});
  refused "missing fixed" (with_action {|{"lane_id":"l","label":"x","from_row":{"a":["a"]}}|});
  refused "empty path" (with_action {|{"lane_id":"l","label":"x","fixed":{},"from_row":{"a":[]}}|});
  refused "nothing read from the row" (with_action {|{"lane_id":"l","label":"x","fixed":{"kind":"k"},"from_row":{}}|});
  refused "member both fixed and from the row" (with_action {|{"lane_id":"l","label":"x","fixed":{"a":1},"from_row":{"a":["a"]}}|});
  refused "blank label" (with_action {|{"lane_id":"l","label":" ","fixed":{},"from_row":{"a":["a"]}}|});
  refused "blank member" (with_action {|{"lane_id":"l","label":"x","fixed":{},"from_row":{" ":["a"]}}|});
  refused "duplicate label in one lane" (Printf.sprintf {|{"actions":[%s,%s]}|} dispute_action dispute_action);
  check bool "the same label on two lanes" true (Result.is_ok (parse
    {|{"actions":[{"lane_id":"a","label":"x","fixed":{},"from_row":{"m":["m"]}},
                  {"lane_id":"b","label":"x","fixed":{},"from_row":{"m":["m"]}}]}|}))

let row_values_are_typed () =
  let fields = json {|{"dispute":{"ask_id":"ask-1","question_id":null},"grading":"done"}|} in
  let is expected path = check bool (String.concat "." path) true (P.row_value path fields = expected) in
  is (P.Present (`String "ask-1")) [ "dispute"; "ask_id" ];
  is P.Absent [ "dispute"; "note" ];
  is P.Absent [ "missing"; "ask_id" ];
  is P.Wrong_shape [ "dispute"; "question_id" ];
  is P.Wrong_shape [ "grading"; "ask_id" ];
  (* Readings keep showing a JSON null as a value. *)
  let reading = { P.lane_id = "l"; path = [ "dispute"; "question_id" ]; label = "q"; unit = None; format = P.Json } in
  check bool "json reading of null" true (P.value reading fields = Ok `Null)

(* A whole lane action tool schema, valid as a worker must advertise it. *)
let tool_name = "lane_act"
let tool action = json (Printf.sprintf {|{"type":"object","properties":{
  "context":{"type":"object","properties":{"instance_id":{"type":"string"},"incarnation":{"type":"string"}},
             "required":["instance_id","incarnation"],"additionalProperties":false},
  "request_id":{"type":"string"},"action":%s},
  "required":["context","request_id","action"],"additionalProperties":false}|} action)
let verdict schema = R.judge ~tool_name ~tool_schema:(tool schema) (action ())
(* The check a send of the filled action meets: the package's kind, the row's
   two ids and a value for each named operator member. *)
let send schema human = Masc.Lane_addon_action.validate ~schema:(tool schema) ~name:tool_name
  (`Assoc [ "context", `Assoc [ "instance_id", `String "quiz"; "incarnation", `String "quiz" ];
            "request_id", `String "r1";
            "action", `Assoc ([ "kind", `String "dispute"; "ask_id", `String "a1"; "question_id", `String "q1" ]
                              @ List.map (fun name -> name, `String "typed") human) ])
let with_keyword key value text = match json text with
  | `Assoc fields -> Yojson.Safe.to_string (`Assoc (fields @ [ key, json value ]))
  | _ -> fail "fixture is not an object"
let string_member = {|{"type":"string"}|}
let branch kind members required = Printf.sprintf
  {|{"type":"object","title":"%s","properties":{"kind":{"type":"string","const":"%s"}%s},"required":[%s],"additionalProperties":false}|}
  kind kind (String.concat "" (List.map (fun name -> Printf.sprintf {|,"%s":%s|} name string_member) members))
  (String.concat "," (List.map (Printf.sprintf {|"%s"|}) ("kind" :: required)))
let three_branches = Printf.sprintf {|{"type":"object","oneOf":[%s,%s,%s]}|}
  (branch "compose" [ "topic" ] [])
  (branch "dispute" [ "ask_id"; "question_id"; "note" ] [ "ask_id"; "question_id"; "note" ])
  (branch "export" [] [])

let verdicts () =
  let offered label expected_branch expected_human schema = match verdict schema with
    | R.Offered { branch; human } ->
        check (option int) (label ^ ": branch") expected_branch branch;
        check (list (pair string bool)) (label ^ ": human members") expected_human
          (List.map (fun (member : R.human_member) -> member.name, member.required) human);
        (* An offer agrees with the send check: the filled action passes, and
           it fails without the operator's required members. *)
        check bool (label ^ ": the filled action sends") true
          (Result.is_ok (send schema (List.map (fun (member : R.human_member) -> member.name) human)));
        check bool (label ^ ": a required operator member is needed")
          (List.exists (fun (member : R.human_member) -> member.required) human)
          (Result.is_error (send schema (List.filter_map (fun (member : R.human_member) ->
               if member.required then None else Some member.name) human)))
    | R.Refused _ -> fail (label ^ ": expected Offered") in
  let refused label expected schema =
    check bool label true (verdict schema = R.Refused expected) in
  (* These schemas pass the advertised schema check, so a worker can send
     them. *)
  let refused_valid label expected schema =
    check bool (label ^ ": a worker can advertise it") true
      (Result.is_ok (Masc.Lane_addon_action.validate_schema (tool schema)));
    refused label expected schema in
  let flat kinds = Printf.sprintf
    {|{"type":"object","properties":{"kind":{"type":"string","enum":[%s]},"ask_id":%s,"question_id":%s,"note":%s},"required":["kind"],"additionalProperties":false}|}
    kinds string_member string_member string_member in
  offered "one closed object" None [ "note", false ] (flat {|"compose","dispute"|});
  offered "three oneOf branches" (Some 1) [ "note", true ] three_branches;
  refused "two branches accept" (R.Several_branches_accept [ 0; 1 ])
    (Printf.sprintf {|{"type":"object","oneOf":[%s,%s]}|}
       (flat {|"dispute"|}) (flat {|"dispute","other"|}));
  refused "no branch accepts" R.No_branch_accepts
    (Printf.sprintf {|{"type":"object","oneOf":[%s,%s]}|}
       (branch "compose" [ "topic" ] []) (branch "export" [] []));
  refused "member the object lacks" (R.Member_not_in_branch "question_id")
    {|{"type":"object","properties":{"kind":{"type":"string"},"ask_id":{"type":"string"}},"additionalProperties":false}|};
  refused "fixed value the object refuses" (R.Fixed_value_rejected "kind") (flat {|"compose"|});
  refused "oneOf inside a branch" R.Schema_shape_unsupported
    (Printf.sprintf {|{"type":"object","oneOf":[{"type":"object","oneOf":[%s]}]}|} (branch "dispute" [ "ask_id"; "question_id" ] []));
  refused "oneOf beside properties" R.Schema_shape_unsupported
    {|{"type":"object","properties":{"kind":{"type":"string"}},"additionalProperties":false,"oneOf":[{"type":"object","properties":{},"additionalProperties":false}]}|};
  refused "open object" R.Schema_shape_unsupported
    {|{"type":"object","properties":{"kind":{"type":"string"},"ask_id":{"type":"string"},"question_id":{"type":"string"}},"additionalProperties":true}|};
  (* A whole-object const or enum limits the action beyond its members. *)
  refused_valid "a const on the oneOf node" R.Schema_shape_unsupported
    (with_keyword "const" {|{"kind":"export"}|} three_branches);
  refused_valid "an enum on a branch" R.Schema_shape_unsupported
    (Printf.sprintf {|{"type":"object","oneOf":[%s,%s]}|} (branch "compose" [ "topic" ] [])
       (with_keyword "enum" {|[{"kind":"dispute","ask_id":"a","question_id":"q"}]|}
          (branch "dispute" [ "ask_id"; "question_id" ] [])));
  refused_valid "a const on the one object" R.Schema_shape_unsupported
    (with_keyword "const" {|{"kind":"compose"}|} (flat {|"compose","dispute"|}));
  check bool "no action property" true
    (R.judge ~tool_name ~tool_schema:(`Assoc [ "type", `String "object" ]) (action ())
     = R.Refused R.Schema_shape_unsupported)

let snapshot_fields () =
  check bool "no actions, no field" true (R.snapshot_fields ~actions:[] ~tool:None = []);
  check bool "no advertised schema" true
    (R.snapshot_fields ~actions:[ action () ] ~tool:None = [ "row_actions", `Null ]);
  check bool "one verdict per action" true
    (R.snapshot_fields ~actions:[ action () ] ~tool:(Some (tool_name, tool three_branches))
     = [ "row_actions", json {|[{"index":0,"offered":{"branch":1,"human":[{"name":"note","required":true}]}}]|} ])

let manifest ~actions_tool ~outputs ~actions = Printf.sprintf {|id = "row-action-probe"
revision = "fixture-1"
title = "Row action probe"
image = "fixture/worker"
command = ["worker"]
contributions = [%s]
%s
[resources]
cpus = 1
memory_bytes = 67108864
pids = 16
max_reply_bytes = 4096
%s
[interface]
presentation = '''{"actions":[%s]}'''
|} (if actions_tool then {|"observe", "act"|} else {|"observe"|})
  (if actions_tool then "\n[world.actions]\ntool = \"lane_act\"\n" else "")
  outputs actions

let port lanes = Printf.sprintf "\n[world.outputs.quiz]\n%s\n" lanes

(* Ports publish lanes to other installations; a package also emits lanes no
   port names, so a row action's lane is not checked against them. *)
let manifest_checks_action_tool () =
  let directory = Filename.temp_dir "row-action-manifest" "" in
  let path = Filename.concat directory "lane.toml" in
  let load text =
    Out_channel.with_open_bin path (fun channel -> output_string channel text);
    Masc.Lane_addon_manifest.load ~path in
  Fun.protect ~finally:(fun () ->
      (try Sys.remove path with Sys_error _ -> ()); (try Sys.rmdir directory with Sys_error _ -> ()))
    (fun () ->
      let actions label result = match result with
        | Ok (package : Masc.Lane_addon_types.package) ->
            List.length package.Masc.Lane_addon_types.presentation.P.actions
        | Error error -> fail (label ^ ": " ^ Masc.Lane_addon_manifest.error_to_string error) in
      let loaded label ~outputs =
        check int label 1 (actions label (load (manifest ~actions_tool:true ~outputs ~actions:dispute_action))) in
      loaded "a lane one port names" ~outputs:(port {|lanes = ["quiz/questions"]|});
      loaded "a port with every lane" ~outputs:(port "all_lanes = true");
      loaded "a lane no port names" ~outputs:(port {|lanes = ["quiz/sessions"]|});
      loaded "no port" ~outputs:"";
      (* The same package loads without the row action, so the action alone
         is what needs the tool. *)
      let outputs = port {|lanes = ["quiz/questions"]|} in
      check int "no action tool and no row action" 0
        (actions "no action tool" (load (manifest ~actions_tool:false ~outputs ~actions:"")));
      check bool "no action tool" true (Result.is_error (load (manifest
        ~actions_tool:false ~outputs ~actions:dispute_action))))

let () =
  run "lane_addon_row_actions" [
    "presentation", [
      test_case "without actions keeps its JSON" `Quick presentation_without_actions_keeps_its_json;
      test_case "actions round trip" `Quick actions_round_trip;
      test_case "invalid actions are refused" `Quick parser_refuses_invalid_actions;
      test_case "row values are typed" `Quick row_values_are_typed;
    ];
    "verdict", [
      test_case "verdicts" `Quick verdicts;
      test_case "snapshot fields" `Quick snapshot_fields;
    ];
    "manifest", [ test_case "row actions need an action tool, not a port" `Quick manifest_checks_action_tool ];
  ]
