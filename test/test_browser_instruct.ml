(* This standalone fixture explicitly enables new Browser work. *)
let () = Browser_lane.install_activity_observer (Some (fun _ -> Browser_lane.Enabled))

(* BrowserInstruct through the browser Add-on tool path: which sentence verb
   each action becomes on the lane it names, and which input reaches no
   browser. The scripted Add-on answers every command it is sent and keeps
   what it was sent. *)
open Alcotest
module Lane = Browser_lane

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path

let answered = Lane.Answered (`Assoc [ "ok", `Bool true; "data", `Assoc [ "tabId", `Int 3 ] ])

let with_instruct run =
  let base = Filename.temp_dir "browser-instruct-test-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base) @@ fun () ->
  Eio_main.run @@ fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  let config = Masc.Workspace.default_config base in
  let sent = ref [] in
  Browser_addon_fixture.with_worker ~env ~config
    ~respond:(fun ~route verb -> sent := (route, verb) :: !sent; answered)
  @@ fun _ ->
  let instruct fields =
    Masc.Browser_addon_tools.handle ~config ~access:Masc.Lane_addon_sources.Operator_configuration
      ~principal:(Lane_addon_call_context.Host_actor "browser-instructor") ~reserved:[]
      ~keeper_name:None ~tool:Masc.Browser_capabilities.Instruct ~tool_name:"masc_browser_instruct"
      ~start_time:(Tool_timing.start ()) (`Assoc fields)
  in
  run ~sent instruct

let on_stagehand fields = ("lane", `String "stagehand") :: ("tabId", `Int 3) :: fields

let test_actions_become_sentence_verbs () =
  with_instruct @@ fun ~sent instruct ->
  List.iter
    (fun (name, fields, expected) ->
      sent := [];
      check bool (name ^ " is served") true (Tool_result.is_success (instruct fields));
      check bool name true (!sent = [ Lane.Stagehand_route, expected ]))
    [ "act becomes an instruction",
      on_stagehand [ "action", `String "act"; "instruction", `String "click Buy" ],
      Lane.Page_instruct { tab_id = 3; instruction = "click Buy" };
      "observe becomes a locate",
      on_stagehand [ "action", `String "observe" ],
      Lane.Page_locate { tab_id = 3; instruction = None };
      "extract carries its schema as JSON",
      on_stagehand
        [ "action", `String "extract"; "instruction", `String "the price";
          "schema", `String {|{"type":"object"}|} ],
      Lane.Page_extract
        { tab_id = 3; instruction = "the price"; schema = Some (`Assoc [ "type", `String "object" ]) } ]

let test_bad_input_reaches_no_browser () =
  with_instruct @@ fun ~sent instruct ->
  List.iter
    (fun (name, fields) ->
      let result = instruct fields in
      check bool (name ^ " is refused as input") true
        (Tool_result.failure_class result = Some Tool_result.Policy_rejection);
      check int (name ^ " reaches no browser") 0 (List.length !sent))
    [ "act without an instruction", on_stagehand [ "action", `String "act" ];
      "a schema on act",
      on_stagehand [ "action", `String "act"; "instruction", `String "x"; "schema", `String "{}" ];
      "a schema that is not JSON",
      on_stagehand [ "action", `String "extract"; "instruction", `String "x"; "schema", `String "{" ];
      "no tab", [ "lane", `String "stagehand"; "action", `String "observe" ];
      "an unknown action", on_stagehand [ "action", `String "click" ];
      "an unknown argument", on_stagehand [ "action", `String "observe"; "url", `String "https://example.org/" ];
      "the live lane", [ "lane", `String "live"; "tabId", `Int 3; "action", `String "observe" ] ]

let () =
  run "browser_instruct"
    [ "Add-on path",
      [ test_case "each action becomes its sentence verb" `Quick test_actions_become_sentence_verbs;
        test_case "bad input reaches no browser" `Quick test_bad_input_reaches_no_browser ] ]
