(** Lane ids read back, the manifest covers every built-in lane, and the
    required exact-output lanes come from one place. *)
open Alcotest
module Lane_id = Masc.Lane_id
module Lane_manifest = Masc.Lane_manifest
module Declaration_file = Masc.Declaration_file
module Machine_lane = Masc.Machine_lane

let builtins = Lane_id.all_of_builtin
let wire_of_builtin builtin = Lane_id.to_wire (Lane_id.Builtin builtin)

let reads_back_as id =
  match Lane_id.of_wire (Lane_id.to_wire id) with
  | Some read -> String.equal (Lane_id.to_wire read) (Lane_id.to_wire id)
  | None -> false
;;

let test_every_builtin_id_reads_back () =
  List.iter
    (fun builtin ->
       let wire = wire_of_builtin builtin in
       check bool (wire ^ " reads back as its own lane") true
         (match Lane_id.of_wire wire with
          | Some (Lane_id.Builtin read) -> Lane_id.equal_builtin read builtin
          | Some (Lane_id.Package _) | None -> false))
    builtins
;;

let test_builtin_wire_ids_are_distinct () =
  let wires = List.map wire_of_builtin builtins in
  check int "no two built-in lanes share a wire id" (List.length wires)
    (List.length (List.sort_uniq String.compare wires))
;;

(* Six exact-output lanes, three Browser Lane backends, two machines: the
   three types' own enumerations, joined. *)
let test_builtins_are_the_three_families () =
  check int "every exact, browser and machine lane once"
    (List.length Standalone_lane.all
     + List.length Browser_lane.Lane_name.all
     + List.length Machine_lane.all)
    (List.length builtins)
;;

let test_unknown_wire_ids_read_as_no_lane () =
  List.iter
    (fun raw -> check bool (Printf.sprintf "%S is no lane" raw) true (Option.is_none (Lane_id.of_wire raw)))
    [ "exact/nope"; "machine/"; "package/a/b"; "package/"; "msx"; ""; "/msx"; "tape/msx"
    ; "exact/librarian_exact/"; "browser/Live" ]
;;

let test_a_package_id_reads_back () =
  match Declaration_file.of_name "dos-counter" with
  | None -> fail "dos-counter is a declaration name"
  | Some file ->
    let id = Lane_id.Package file in
    check string "package wire" "package/dos-counter" (Lane_id.to_wire id);
    check bool "and it reads back" true (reads_back_as id)
;;

let test_declaration_file_names () =
  let name raw = Option.map Declaration_file.to_string (Declaration_file.of_file_name raw) in
  check (option string) "a .toml file is a declaration" (Some "dos-counter") (name "dos-counter.toml");
  check (option string) "a file without the suffix is not" None (name "dos-counter");
  check (option string) "the suffix alone names nothing" None (name ".toml");
  check (option string) "a path is not a file name" None (name "lane-addons/dos-counter.toml")
;;

let test_required_ids_are_board_attention_and_hitl () =
  check (list string) "the two required exact-output lanes"
    [ Standalone_lane.to_id Standalone_lane.Hitl_auto_judge
    ; Standalone_lane.to_id Standalone_lane.Board_attention ]
    Standalone_lane.required_ids
;;

(* Moved from test_exact_lane_run_registry with the hand-written [all]:
   rows, the projection and the TUI read a lane id back through [of_id]. *)
let test_every_standalone_id_reads_back () =
  List.iter
    (fun lane ->
       let id = Standalone_lane.to_id lane in
       check bool (id ^ " reads back as its own lane") true
         (match Standalone_lane.of_id id with
          | Some read -> Standalone_lane.equal read lane
          | None -> false))
    Standalone_lane.all;
  check bool "an id no lane has reads as no lane" true
    (Option.is_none (Standalone_lane.of_id "verifer_exact"))
;;

let test_every_builtin_has_a_label_and_purpose () =
  let labels = List.map Lane_manifest.label builtins in
  List.iter
    (fun builtin ->
       check bool (wire_of_builtin builtin ^ " has a label") true
         (String.length (Lane_manifest.label builtin) > 0);
       check bool (wire_of_builtin builtin ^ " has a purpose") true
         (String.length (Lane_manifest.purpose builtin) > 0))
    builtins;
  check int "no two lanes share a label" (List.length labels)
    (List.length (List.sort_uniq String.compare labels))
;;

let tool_names builtin =
  List.map Tool_schemas_misc.misc_tool_name (Lane_manifest.tools builtin)
;;

(* Sessions and navigation belong to the backends whose browser the server
   owns; the live browser belongs to the operator. *)
let test_browser_tools_follow_the_lane_argument () =
  let session_lanes = Lane_manifest.lanes_of_misc_operation Tool_schemas_misc.Misc_browser_session in
  check bool "the live browser takes no session" false
    (List.exists (Lane_id.equal_builtin (Lane_id.Browser Browser_lane.Lane_name.Live)) session_lanes);
  check bool "automation and stagehand take sessions" true
    (List.for_all
       (fun lane -> List.exists (Lane_id.equal_builtin (Lane_id.Browser lane)) session_lanes)
       [ Browser_lane.Lane_name.Automation; Browser_lane.Lane_name.Stagehand ]);
  check (list string) "the live browser is read and acted on"
    [ "masc_browser_tabs"; "masc_browser_read"; "masc_browser_act"; "masc_browser_interact" ]
    (tool_names (Lane_id.Browser Browser_lane.Lane_name.Live))
;;

let test_machine_tools_belong_to_their_machine () =
  let msx = Lane_manifest.tools (Lane_id.Machine Machine_lane.Msx) in
  let dos = Lane_manifest.tools (Lane_id.Machine Machine_lane.Dos) in
  check bool "MSX has tools" true (msx <> []);
  check bool "DOS has tools" true (dos <> []);
  check bool "no tool drives both machines" true
    (List.for_all (fun operation -> not (List.mem operation dos)) msx);
  check (list string) "masc_dos_screen is a DOS tool" [ "masc_dos_screen" ]
    (List.filter (String.equal "masc_dos_screen") (tool_names (Lane_id.Machine Machine_lane.Dos)))
;;

let test_exact_lanes_and_lane_addon_tools_have_no_typed_tools () =
  List.iter
    (fun lane ->
       check (list string) (Standalone_lane.to_id lane ^ " contributes no misc tool") []
         (tool_names (Lane_id.Exact lane)))
    Standalone_lane.all;
  check int "masc_lane_act acts on package installations, no built-in lane" 0
    (List.length (Lane_manifest.lanes_of_misc_operation Tool_schemas_misc.Misc_lane_act))
;;

let () =
  run "lane_id"
    [ ( "wire"
      , [ test_case "every built-in id reads back" `Quick test_every_builtin_id_reads_back
        ; test_case "built-in wire ids are distinct" `Quick test_builtin_wire_ids_are_distinct
        ; test_case "built-ins are the three families" `Quick test_builtins_are_the_three_families
        ; test_case "unknown wire ids read as no lane" `Quick test_unknown_wire_ids_read_as_no_lane
        ; test_case "a package id reads back" `Quick test_a_package_id_reads_back
        ; test_case "declaration file names" `Quick test_declaration_file_names
        ] )
    ; ( "standalone"
      , [ test_case "required ids are Board Attention and HITL" `Quick
            test_required_ids_are_board_attention_and_hitl
        ; test_case "every standalone id reads back" `Quick test_every_standalone_id_reads_back
        ] )
    ; ( "manifest"
      , [ test_case "every built-in has a label and purpose" `Quick
            test_every_builtin_has_a_label_and_purpose
        ; test_case "browser tools follow the lane argument" `Quick
            test_browser_tools_follow_the_lane_argument
        ; test_case "machine tools belong to their machine" `Quick
            test_machine_tools_belong_to_their_machine
        ; test_case "exact lanes and lane add-on tools have no typed tools" `Quick
            test_exact_lanes_and_lane_addon_tools_have_no_typed_tools
        ] )
    ]
;;
