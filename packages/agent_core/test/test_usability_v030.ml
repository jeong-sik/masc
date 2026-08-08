(** Usability test — verifies that v0.30.0 features compose naturally
    from a user's perspective.  These are not unit tests; they exercise
    the Builder -> Agent -> Card -> Registry pipeline end-to-end. *)

open Agent_sdk

let card_interfaces =
  Agent_card.create_supported_interface
    ~url:"https://test-agent.example/a2a"
    ~protocol_binding:"JSONRPC"
    ~protocol_version:"1.0"
    ()
  |> Result.get_ok
  |> fun interface -> Agent_card.supported_interfaces interface []
;;

let build_exn b =
  match Builder.build_safe b with
  | Ok agent -> agent
  | Error e -> failwith (Error.to_string e)
;;

(* Helper: extract card fields via JSON to avoid internal module path issues *)
let card_name card =
  card
  |> Agent_card.to_json
  |> Yojson.Safe.Util.member "name"
  |> Yojson.Safe.Util.to_string
;;

let card_desc card =
  match card |> Agent_card.to_json |> Yojson.Safe.Util.member "description" with
  | `Null -> None
  | v -> Some (Yojson.Safe.Util.to_string v)
;;

let card_skill_count card =
  card
  |> Agent_card.to_json
  |> Yojson.Safe.Util.member "skills"
  |> Yojson.Safe.Util.to_list
  |> List.length
;;

(* ── Scenario 1: Builder-driven agent with skill registry ── *)

let test_builder_with_skill_registry () =
  Eio_main.run
  @@ fun env ->
  let reg = Skill_registry.create () in
  Skill_registry.register
    reg
    (Skill.of_markdown
       "---\nname: summarize\ndescription: Summarize text\n---\nSummarize: $ARGUMENTS");
  Skill_registry.register
    reg
    (Skill.of_markdown
       "---\nname: translate\ndescription: Translate text\n---\nTranslate: $ARGUMENTS");
  let agent =
    Builder.create ~net:env#net ~model:"claude-sonnet-4-6"
    |> Builder.with_name "polyglot"
    |> Builder.with_description "A multilingual assistant"
    |> Builder.with_skill_registry reg
    |> build_exn
  in
  let card = Agent.card ~supported_interfaces:card_interfaces agent in
  Alcotest.(check string) "card name" "polyglot" (card_name card);
  Alcotest.(check (option string))
    "card desc"
    (Some "A multilingual assistant")
    (card_desc card);
  Alcotest.(check int) "2 skills" 2 (card_skill_count card);
  Alcotest.(check bool) "has summarize" true (Agent_card.has_skill card "summarize");
  Alcotest.(check bool) "has translate" true (Agent_card.has_skill card "translate");
  Alcotest.(check bool)
    "has Streaming"
    true
    (Agent_card.has_capability card Agent_card.Streaming)
;;

(* ── Scenario 2: Card JSON export for multi-agent discovery ── *)

let test_card_json_export () =
  Eio_main.run
  @@ fun env ->
  let tool =
    Tool.create
      ~name:"search"
      ~description:"Search the web"
      ~parameters:
        [ { name = "query"; description = "Query"; param_type = String; required = true }
        ]
      (fun _input -> Ok { Types.content = "results"; _meta = None })
  in
  let agent =
    Builder.create ~net:env#net ~model:"claude-sonnet-4-6"
    |> Builder.with_name "researcher"
    |> Builder.with_tools [ tool ]
    |> Builder.with_enable_thinking true
    |> Builder.with_thinking_budget 2000
    |> build_exn
  in
  let card = Agent.card ~supported_interfaces:card_interfaces agent in
  let json = Agent_card.to_json card in
  let open Yojson.Safe.Util in
  let name = json |> member "name" |> to_string in
  let caps = json |> member "capabilities" |> to_list |> List.map to_string in
  let tools = json |> member "tools" |> to_list in
  Alcotest.(check string) "json name" "researcher" name;
  Alcotest.(check bool) "has tools cap" true (List.mem "tools" caps);
  Alcotest.(check bool) "has thinking cap" true (List.mem "thinking" caps);
  Alcotest.(check bool) "has streaming cap" true (List.mem "streaming" caps);
  Alcotest.(check int) "1 tool in json" 1 (List.length tools);
  match Agent_card.of_json json with
  | Ok parsed ->
    Alcotest.(check string) "parsed name" "researcher" (card_name parsed);
    Alcotest.(check bool)
      "parsed has Tools"
      true
      (Agent_card.has_capability parsed Agent_card.Tools)
  | Error e -> Alcotest.fail (Error.to_string e)
;;

(* ── Scenario 3: Elicitation via Builder ── *)

let test_builder_with_elicitation () =
  Eio_main.run
  @@ fun env ->
  let elicit_called = ref false in
  let cb : Hooks.elicitation_callback =
    fun req ->
    elicit_called := true;
    Hooks.Answer (`String (Printf.sprintf "user chose: %s" req.question))
  in
  let agent =
    Builder.create ~net:env#net ~model:"claude-sonnet-4-6"
    |> Builder.with_name "interactive"
    |> Builder.with_elicitation cb
    |> build_exn
  in
  let card = Agent.card ~supported_interfaces:card_interfaces agent in
  Alcotest.(check bool)
    "elicitation cap"
    true
    (Agent_card.has_capability card Agent_card.Elicitation);
  let opts = Agent.options agent in
  Alcotest.(check bool) "has elicitation" true (Option.is_some opts.elicitation);
  match opts.elicitation with
  | Some cb ->
    let resp =
      cb { Hooks.question = "prod or staging?"; schema = None; timeout_s = None }
    in
    (match resp with
     | Hooks.Answer (`String s) ->
       Alcotest.(check string) "answer" "user chose: prod or staging?" s
     | _ -> Alcotest.fail "expected Answer");
    Alcotest.(check bool) "cb was called" true !elicit_called
  | None -> Alcotest.fail "elicitation missing"
;;

(* ── Scenario 4: Skill registry persistence ── *)

let test_registry_persist_and_restore () =
  let reg = Skill_registry.create () in
  Skill_registry.register
    reg
    (Skill.of_markdown
       "---\nname: deploy\ndescription: Deploy app\n---\ndeploy $ARGUMENTS");
  Skill_registry.register
    reg
    (Skill.of_markdown
       "---\nname: rollback\ndescription: Rollback\n---\nrollback $ARGUMENTS");
  let json = Skill_registry.to_json reg in
  let json_str = Yojson.Safe.to_string json in
  let json2 = Yojson.Safe.from_string json_str in
  match Skill_registry.of_json json2 with
  | Ok reg2 ->
    Alcotest.(check int) "count" 2 (Skill_registry.count reg2);
    (match Skill_registry.find reg2 "deploy" with
     | Some s ->
       Alcotest.(check string) "body" "deploy $ARGUMENTS" s.body;
       let rendered = Skill.render_prompt ~arguments:"v2.1" s in
       Alcotest.(check string) "rendered" "deploy v2.1" rendered
     | None -> Alcotest.fail "deploy not found after restore")
  | Error e -> Alcotest.fail (Error.to_string e)
;;

(* ── Scenario 5: description flows through ── *)

let test_description_accessor () =
  Eio_main.run
  @@ fun env ->
  let agent =
    Builder.create ~net:env#net ~model:"claude-sonnet-4-6"
    |> Builder.with_name "helper"
    |> Builder.with_description "A helpful assistant"
    |> build_exn
  in
  Alcotest.(check (option string))
    "description"
    (Some "A helpful assistant")
    (Agent.description agent);
  let agent2 =
    Builder.create ~net:env#net ~model:"claude-sonnet-4-6"
    |> Builder.with_name "minimal"
    |> build_exn
  in
  Alcotest.(check (option string)) "no description" None (Agent.description agent2)
;;

let () =
  let open Alcotest in
  run
    "Usability_v030"
    [ ( "builder_integration"
      , [ test_case "skill registry via builder" `Quick test_builder_with_skill_registry
        ; test_case "card JSON export" `Quick test_card_json_export
        ; test_case "elicitation via builder" `Quick test_builder_with_elicitation
        ] )
    ; ( "persistence"
      , [ test_case
            "registry persist and restore"
            `Quick
            test_registry_persist_and_restore
        ] )
    ; ( "accessors"
      , [ test_case "description flows through" `Quick test_description_accessor ] )
    ]
;;
