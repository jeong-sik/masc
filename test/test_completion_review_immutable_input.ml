(* Actual wrapper -> Agent Core -> HTTP peer regression source. A third reply
   detects unwanted re-entry. The existing checkpoint fence can also prevent
   it, so this is not an isolated negative control for the new source branch. *)
open Masc

let model_id = "completion-evidence-fixture"
let contradiction = "EARLY_REFUTATION_MUST_REMAIN: " ^ String.make 32768 'e'
let goal = "Inspect the evidence and report the contradiction."
let lookup_name = "inspect_evidence"

let response message finish_reason =
  Yojson.Safe.to_string (`Assoc
    ["id",`String "evidence-peer";"model",`String model_id;
     "choices",`List [`Assoc ["index",`Int 0;"message",message;
       "finish_reason",`String finish_reason]];
     "usage",`Assoc ["prompt_tokens",`Int 1;"completion_tokens",`Int 1;
       "total_tokens",`Int 2]])

let tool_reply = response
  (`Assoc ["role",`String "assistant";"content",`Null;
    "tool_calls",`List [`Assoc ["id",`String "read-proof";
      "type",`String "function";"function",`Assoc
        ["name",`String lookup_name;"arguments",`String {|{"piece":"early-refutation"}|}]]]])
  "tool_calls"

let wrong_success = response
  (`Assoc ["role",`String "assistant";"content",`String "wrong shortened answer"])
  "stop"

let write path text = Out_channel.with_open_bin path (fun channel ->
  output_string channel text)

let run_refusal ~body_limit () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Model_catalog.global () in
  let base_path = Filename.temp_file "completion-evidence-" ".dir" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    (match catalog_snapshot with
     | None -> Llm_provider.Model_catalog.clear_global ()
     | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
    Fs_compat.remove_tree base_path);
  let bodies = ref [] in
  let callback _connection _request body =
    let text = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    bodies := !bodies @ [text];
    let status, answer = match List.length !bodies with
      | 1 -> `OK, tool_reply
      | 2 when body_limit -> `Request_entity_too_large, {|{"error":{"message":"request too large"}}|}
      | 2 -> `OK, response
          (`Assoc ["role",`String "assistant";"content",`String ""])
          "model_context_window_exceeded"
      | _ -> `OK, wrong_success in
    Cohttp_eio.Server.respond_string ~status ~body:answer ()
  in
  let socket = Eio.Net.listen env#net ~sw ~backlog:8 ~reuse_addr:true
    (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_,port) -> port | `Unix _ -> Alcotest.fail "expected TCP peer" in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket (Cohttp_eio.Server.make ~callback ())
      ~on_error:raise);
  let catalog_path = Filename.concat base_path "models.toml" in
  write catalog_path (Printf.sprintf
    "[[models]]\nmodel_id = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 1048576\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n"
    model_id);
  (match Llm_provider.Model_catalog.load_file catalog_path with
   | Ok catalog -> Llm_provider.Model_catalog.set_global catalog
   | Error detail -> Alcotest.fail detail);
  let config_path = Filename.concat base_path "runtime.toml" in
  write config_path (Printf.sprintf
    "[runtime]\ndefault = \"fixture.sample\"\n[providers.fixture]\nprotocol = \"openai-compatible-http\"\nendpoint = \"http://127.0.0.1:%d\"\n[models.sample]\napi-name = %S\nmax-context = 1048576\ntools-support = true\nstreaming = false\n[fixture.sample]\n"
    port model_id);
  (match Runtime.init_default ~config_path with
   | Ok () -> () | Error detail -> Alcotest.fail detail);
  let reads = ref 0 in
  let result = Keeper_turn_driver_wrappers.run_named_with_masc_tools
    ~input_source:Masc.Keeper_request_source.Completion_review
    ~runtime_id:"fixture.sample" ~keeper_name:"completion-evidence"
    ~walk_owner:Keeper_turn_driver.One_shot_walk ~base_path ~media_store:(Tool_blob_media_store.of_base_path ~base_path) ~goal
    ~system_prompt:"Review the original evidence."
    ~raw_trace:None
    ~masc_tools:[{Masc_domain.name=lookup_name;description="Read the original evidence";
      input_schema=`Assoc ["type",`String "object";
        "properties",`Assoc ["piece",`Assoc ["type",`String "string"]]]}]
    ~tool_result_projection:(Tool_output.Inline_up_to
      {maximum_bytes=Tool_shard_limits.verification_evidence_max_bytes})
    ~dispatch:(fun ~name ~args ->
      Alcotest.(check string) "actual lookup tool" lookup_name name;
      Alcotest.(check string) "original lookup argument" "early-refutation"
        Yojson.Safe.Util.(args |> member "piece" |> to_string);
      incr reads;
      Tool_result.ok ~tool_name:name ~start_time:(Tool_timing.start ()) contradiction)
    ~sw ~net:env#net () in
  (match result with
   | Ok _ -> Alcotest.fail "a shortened retry converted refusal into success"
   | Error (Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) when not body_limit -> ()
   | Error (Agent_core.Error.Api (Agent_core.Retry.InvalidRequest
       {reason=Agent_core.Retry.Request_body_refused_by_provider _;_})) when body_limit -> ()
   | Error error -> Alcotest.fail (Agent_core.Error.to_string error));
  Alcotest.(check int) "lookup ran once" 1 !reads;
  Alcotest.(check int) "no third marker retry reaches the real peer" 2 (List.length !bodies);
  let offered = List.nth !bodies 1 |> Yojson.Safe.from_string in
  let messages = Yojson.Safe.Util.(offered |> member "messages" |> to_list) in
  let tool_rows = List.filter (fun row ->
    Yojson.Safe.Util.member "role" row = `String "tool") messages in
  Alcotest.(check int) "the actual ToolResult remains paired" 1 (List.length tool_rows);
  let calls = List.concat_map (fun message ->
    match Yojson.Safe.Util.member "tool_calls" message with
    | `List calls -> calls
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> []) messages in
  Alcotest.(check int) "the original assistant ToolUse remains" 1 (List.length calls);
  let call = List.hd calls in
  Alcotest.(check string) "assistant call identity" "read-proof"
    Yojson.Safe.Util.(call |> member "id" |> to_string);
  let fn = Yojson.Safe.Util.member "function" call in
  Alcotest.(check string) "assistant lookup name" lookup_name
    Yojson.Safe.Util.(fn |> member "name" |> to_string);
  let arguments = Yojson.Safe.Util.(fn |> member "arguments" |> to_string) |> Yojson.Safe.from_string in
  Alcotest.(check string) "assistant original lookup arguments" "early-refutation"
    Yojson.Safe.Util.(arguments |> member "piece" |> to_string);
  let row = List.hd tool_rows in
  Alcotest.(check string) "original call identity survives" "read-proof"
    Yojson.Safe.Util.(row |> member "tool_call_id" |> to_string);
  (* The bridge may wrap typed result metadata; inspect its JSON tree instead
     of weakening this to a marker/prefix test. *)
  let rec contains = function
    | `String value -> value=contradiction
    | `Assoc fields -> List.exists (fun (_,value)->contains value) fields
    | `List values -> List.exists contains values
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ -> false in
  let content = Yojson.Safe.Util.(row |> member "content" |> to_string) in
  let complete = if content=contradiction then true else
    try contains (Yojson.Safe.from_string content) with Yojson.Json_error _ -> false in
  Alcotest.(check bool) "the peer received the whole contradictory lookup" true complete;
  Alcotest.(check bool) "the original review request remains" true
    (List.exists (fun row -> Yojson.Safe.Util.member "content" row = `String goal) messages)

let () = Alcotest.run "completion review immutable evidence"
  ["actual wrapper and peer",
    [Alcotest.test_case "context refusal preserves current lookup" `Quick (run_refusal ~body_limit:false);
     Alcotest.test_case "body refusal preserves current lookup" `Quick (run_refusal ~body_limit:true)]]
