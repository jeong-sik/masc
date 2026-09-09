open Alcotest
module Driver = Masc.Browser_webdriver
module Lane = Browser_lane
module Action = Browser_lane.Action
let start_downloads ~session_id:_ ~websocket_url:_ =
  Ok Masc.Browser_downloads.{read=(fun ~context:_ -> Ok (`Assoc ["downloads",`List []]));
    check=(fun () -> Ok ());close=(fun () -> ())}

let make_meta () =
  match Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String "browser-upload"]) with
  | Ok meta -> {meta with Masc.Keeper_meta_contract.sandbox_profile = Keeper_types_profile_sandbox.Docker}
  | Error error -> fail error
let rec mkdir_p path =
  if not (Sys.file_exists path) then (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  | _ -> Unix.unlink path
let with_upload_context f =
  let base = Filename.temp_dir "browser-upload-test-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () ->
    let config = Masc.Workspace.default_config base in
    let meta = make_meta () in
    mkdir_p (Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta);
    f config meta)
let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let ok = function
  | Lane.Answered (`Assoc fields) -> (match List.assoc_opt "data" fields with Some data -> data | None -> fail "no data")
  | Lane.Refused message | Lane.Rejected_before_effect message -> fail message
  | _ -> fail "browser did not answer"
let fixture ?(failure=(fun _ -> None)) f = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  let current = ref "a" in
  let calls = ref [] in
  let matches = ref 1 in
  let request ~method_ ~path ~body =
    Eio.Fiber.yield ();
    calls := (!current,method_,path,body) :: !calls;
    match failure path with
    | Some error -> Error error
    | None ->
    match method_,path with
    | `DELETE,"/session/s" -> Ok `Null
    | `POST,"/session" -> Ok (`Assoc ["sessionId",`String "s";"capabilities",`Assoc ["webSocketUrl",`String "ws://localhost:1234/session/s"]])
    | `GET,"/session/s/window/handles" -> Ok (`List [`String "a";`String "b"])
    | `GET,"/session/s/window" -> Ok (`String !current)
    | `POST,"/session/s/window" ->
      (match Option.bind body (field "handle") with
       | Some (`String handle) -> current := handle; Ok `Null
       | _ -> fail "missing window handle")
    | `POST,"/session/s/execute/sync" ->
      if Option.bind body (field "script") = Some (`String "return arguments[0].localName==='input' && arguments[0].type==='file';")
      then Ok (`Bool true)
      else Ok (`Assoc ["url",`String ("https://example.org/" ^ !current);"title",`String !current])
    | `POST,"/session/s/elements" -> Ok (`List (List.init !matches (fun _ ->
        `Assoc ["element-6066-11e4-a52e-4f735466cecf",`String (!current ^ "_button")])))
    | `POST,"/session/s/window/new" -> Ok (`Assoc ["handle",`String "c"])
    | `POST,_ -> Ok `Null
    | `DELETE,"/session/s/window" -> Ok (`List [`String "a"])
    | _ -> fail ("unexpected request " ^ path) in
  let driver = Driver.create ~start_downloads ~request () in
  ignore (ok (Driver.execute driver (Lane.Session_open {headless=None})));
  ignore (ok (Driver.execute driver Lane.Tabs_list));
  calls := [];
  f driver current calls matches)
let act driver tab_id interaction = Driver.execute driver (Lane.Page_act (Action.On_tab {tab_id;frame_path=[];interaction}))
let test_targeted_goto () = fixture (fun driver current calls _ ->
  ignore (ok (Driver.execute driver (Lane.Page_goto {url="https://example.org/new";tab_id=Some 2})));
  check string "navigation selects observed tab" "b" !current;
  check bool "URL request occurs in target tab" true
    (List.exists (fun (tab,_,path,_) -> tab="b" && path="/session/s/url") !calls);
  calls := [];
  (match Driver.execute driver (Lane.Page_goto {url="https://example.org/new";tab_id=Some 99}) with
   | Lane.Refused _ -> () | _ -> fail "unknown tab accepted");
  check int "unknown tab cannot navigate current tab" 0 (List.length !calls))
let test_selector_contract () = fixture (fun driver _ calls matches ->
  List.iter (fun count -> matches := count; calls := [];
    (match act driver 1 (Action.Click "button") with Lane.Rejected_before_effect _ -> () | _ -> fail "non-unique selector accepted");
    check bool "no click after absent or ambiguous selector" false
      (List.exists (fun (_,_,path,_) -> String.ends_with ~suffix:"/click" path) !calls)) [0;2])
let test_native_fill_and_key () = fixture (fun driver _ calls _ ->
  ignore (ok (act driver 2 (Action.Fill {selector="#name";text="한글'\n🙂"})));
  let commands = List.rev !calls |> List.filter (fun (_,_,path,_) -> String.starts_with ~prefix:"/session/s/element/" path) in
  (match commands with
   | [("b",`POST,"/session/s/element/b_button/clear",_);
      ("b",`POST,"/session/s/element/b_button/value",Some body)] ->
      check bool "text travels as JSON, not code" true (field "text" body = Some (`String "한글'\n🙂"))
   | _ -> fail "fill must clear then send native keys in selected tab");
  ignore (ok (act driver 2 (Action.Press {selector="#name";key=Action.Enter})));
  match List.hd !calls with
  | _,_,"/session/s/element/b_button/value",Some body ->
    check bool "Enter uses WebDriver key code" true (field "text" body = Some (`String "\xee\x80\x87"))
  | _ -> fail "native key command missing")
let test_parallel_targeting () = fixture (fun driver _ calls _ ->
  Eio.Fiber.both
    (fun () -> ignore (ok (act driver 1 (Action.Click "button"))))
    (fun () -> ignore (ok (act driver 2 (Action.Click "button"))));
  let clicks = List.filter_map (fun (tab,_,path,_) ->
    if String.ends_with ~suffix:"/click" path then Some (tab,path) else None) !calls in
  check int "both interactions completed" 2 (List.length clicks);
  List.iter (fun (tab,path) -> check string "tab selection and click are atomic"
    ("/session/s/element/" ^ tab ^ "_button/click") path) clicks)
let test_parser () =
  let valid = `Assoc ["action",`String "fill";"tabId",`Int 2;"selector",`String "#name";"text",`String ""] in
  (match Action.parse valid with Ok action -> check bool "round trip" true (Action.parse (Action.to_json action)=Ok action) | Error e -> fail e);
  List.iter (fun fields -> check bool "invalid action rejected" true (Result.is_error (Action.parse (`Assoc fields))))
    [["action",`String "click";"selector",`String "button"];
     ["action",`String "click";"tabId",`Int 1;"selector",`String ""];
     ["action",`String "reload";"tabId",`Int 1;"text",`String "ignored?"];
     ["action",`String "reload";"tabId",`Int 1;"tabId",`Int 2]]
let test_stale_session_id () = fixture (fun driver _ calls _ ->
  ignore (ok (Driver.execute driver Lane.Session_close));
  ignore (ok (Driver.execute driver (Lane.Session_open {headless=None})));
  ignore (ok (Driver.execute driver Lane.Tabs_list));
  calls := [];
  (match act driver 1 (Action.Click "button") with
   | Lane.Rejected_before_effect _ -> () | _ -> fail "stale tab id targeted the new session");
  check int "stale target causes no browser request" 0 (List.length !calls))
let test_pre_effect_tool_outcome () = with_upload_context (fun config meta -> fixture (fun driver _ calls matches ->
  Eio.Switch.run (fun sw ->
    Lane.install_automation_executor (Some (Driver.execute driver));
    Eio.Switch.on_release sw (fun () -> Lane.install_automation_executor None);
    let invoke fields = Masc.Keeper_tool_in_process_runtime.handle_browser_act_with_outcome
      ~turn_sandbox_factory:None ~config ~meta ~args:(`Assoc fields) in
    let missing = invoke ["action",`String "click";"selector",`String "button"] in
    check bool "missing target permits correction" true
      (missing.failure_effect_disposition = Tool_result.Proven_pre_effect);
    matches := 0;
    let absent = invoke ["action",`String "click";"selector",`String "button";"tabId",`Int 1] in
    check bool "absent element permits correction" true
      (absent.failure_effect_disposition = Tool_result.Proven_pre_effect);
    calls := [];
    let upload = ["action",`String "upload";"selector",`String "input";"tabId",`Int 1;
      "paths",`List [`String (Filename.concat config.base_path "outside-secret")]] in
    let denied = invoke upload in
    check bool "outside upload is pre-effect" true (denied.failure_effect_disposition = Tool_result.Proven_pre_effect);
    check int "denied upload sends no browser commands, including clear" 0 (List.length !calls);
    let _,phase = Masc.Tool_misc_browser_lane.handle_act_with_phase
        ~tool_name:"masc_browser_act" ~start_time:0.0 (`Assoc upload) in
    check bool "generic upload requires owner" true (phase = Tool_result.Proven_pre_effect);
    check int "generic upload sends no browser commands" 0 (List.length !calls))))
let test_owned_upload_staging () = with_upload_context (fun config meta -> fixture (fun driver _ _ _ ->
  let root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let source = Filename.concat root "payload.bin" in
  let oc = open_out_bin source in close_out oc;
  let captured = ref [] in
  let bytes = "\000\255\n" ^ root ^ "\000" in
  let read_file ~host_path ~max_bytes =
    check string "reader gets owner-projected host path" (Unix.realpath source) host_path;
    check int "reader includes oversize sentinel" (Masc.Keeper_browser_upload.max_file_bytes+1) max_bytes;
    Ok bytes in
  let outcome = Masc.Keeper_browser_upload.with_staged_paths ~read_file ~config ~meta
    ~paths:["payload.bin"] (fun paths ->
      captured := paths;
      let staged = List.hd paths in
      check bool "browser never receives mutable source path" false (staged=source);
      check string "browser filename preserved" "payload.bin" (Filename.basename staged);
      let ic = open_in_bin staged in
      let actual = Fun.protect ~finally:(fun () -> close_in ic)
        (fun () -> really_input_string ic (in_channel_length ic)) in
      check string "exact binary snapshot" bytes actual;
      act driver 1 (Action.Upload {selector="input";paths})) in
  (match outcome with
   | Ok (Lane.Answered _) -> ()
   | _ -> fail "owned binary snapshot did not reach native upload");
  List.iter (fun path -> check bool "snapshot survives selection completion" true (Sys.file_exists path)) !captured;
  (match Driver.close driver with Ok () -> () | Error error -> fail (Driver.error_message error));
  List.iter (fun path -> check bool "snapshot removed after confirmed session close" false (Sys.file_exists path)) !captured;
  check bool "caller source survives session cleanup" true (Sys.file_exists source);
  let invoked = ref false in
  let result = Masc.Keeper_browser_upload.with_staged_paths
    ~read_file:(fun ~host_path:_ ~max_bytes -> Ok (String.make max_bytes 'x'))
    ~config ~meta ~paths:["payload.bin"] (fun _ -> invoked := true) in
  check bool "oversized files are refused" true (Result.is_error result);
  check bool "oversized bytes never reach browser" false !invoked))
let test_upload_lease_failures () =
  let failing = ref false in
  let failure path = if !failing &&
    (String.ends_with ~suffix:"/value" path || path="/session/s")
    then Some (Driver.Transport "response timed out") else None in
  fixture ~failure (fun driver _ _ matches ->
    let captured = ref [] in
    let stage f = Lane.Upload_lease.with_staged_files
        ~files:["payload.bin",(fun () -> Ok "bytes")]
        (fun paths -> captured := paths; f paths) in
    matches := 0;
    (match stage (fun paths -> act driver 1 (Action.Upload {selector="input";paths})) with
     | Ok (Lane.Rejected_before_effect _) -> () | _ -> fail "absent input should reject before effect");
    List.iter (fun path -> check bool "pre-effect snapshot is cleaned" false (Sys.file_exists path)) !captured;
    matches := 1; failing := true;
    (match stage (fun paths -> act driver 1 (Action.Upload {selector="input";paths})) with
     | Ok (Lane.Refused _) -> () | _ -> fail "uncertain upload should fail with effect uncertainty");
    List.iter (fun path -> check bool "uncertain upload retains File backing" true (Sys.file_exists path)) !captured;
    check bool "unconfirmed close fails" true (Result.is_error (Driver.close driver));
    List.iter (fun path -> check bool "unconfirmed close retains files" true (Sys.file_exists path)) !captured;
    failing := false;
    check bool "confirmed close succeeds" true (Result.is_ok (Driver.close driver));
    List.iter (fun path -> check bool "confirmed close releases files" false (Sys.file_exists path)) !captured)
let test_upload_lease_cancellation () = Eio_main.run (fun _ ->
  let owner = Lane.Upload_lease.create_owner () in
  let claimed,resolve = Eio.Promise.create () in
  let paths = ref [] in
  Eio.Fiber.first
    (fun () -> match Lane.Upload_lease.with_staged_files ~files:["payload.bin",(fun () -> Ok "bytes")]
       (fun staged -> paths := staged; Lane.Upload_lease.claim ~owner ~paths:staged;
         Eio.Promise.resolve resolve (); Eio.Fiber.await_cancel ()) with
       | Ok () -> () | Error error -> fail error)
    (fun () -> Eio.Promise.await claimed);
  List.iter (fun path -> check bool "cancelled callback retains claimed bytes" true (Sys.file_exists path)) !paths;
  Lane.Upload_lease.release_owner owner;
  List.iter (fun path -> check bool "confirmed owner teardown releases cancelled upload" false (Sys.file_exists path)) !paths)
let test_context_arguments () =
  let valid action args = `Assoc (["action",`String action;"tabId",`Int 1] @ args) in
  List.iter (fun input -> match Action.parse input with
    | Ok action -> check bool "context round trip" true (Action.parse (Action.to_json action) = Ok action)
    | Error detail -> fail detail)
    [valid "click" ["selector",`String "#apply";"framePath",`List [`String "iframe";`String "#nested"]];
     valid "accept_dialog" ["text",`String "한글"];
     valid "dismiss_dialog" [];
     valid "upload" ["selector",`String "input";"paths",`List [`String "relative.txt"]];
     valid "upload" ["selector",`String "input";"paths",`List [`String "/fixture/file.txt"]]];
  List.iter (fun input -> check bool "invalid context rejected" true (Result.is_error (Action.parse input)))
    [valid "click" ["selector",`String "button";"framePath",`List [`Int 1]];
     valid "click" ["selector",`String "button";"framePath",`List [`String ""]];
     valid "accept_dialog" ["framePath",`List [`String "iframe"]];
     valid "upload" ["selector",`String "input";"paths",`List []];
     valid "upload" ["selector",`String "input";"paths",`List [`String "/file\n/other"]]]
let test_download_result_reaches_provider () =
  with_upload_context (fun config meta -> Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let path = Filename.concat config.base_path "download.bin" in
      let bytes = String.init 40000 (fun i -> Char.chr (i mod 256)) in
      Out_channel.with_open_bin path (fun oc -> output_string oc bytes);
      let artifact = match Masc.Browser_download_artifact.publish ~base_path:config.base_path path with
        | Ok value -> value | Error detail -> fail detail in
      let payload = `Assoc ["downloads", `List [`Assoc ["artifact", artifact]]] in
      Lane.install_automation_executor (Some (function
        | Lane.Page_downloads {tab_id=1} ->
          Lane.Answered (`Assoc ["ok",`Bool true;"data",payload])
        | _ -> fail "unexpected browser action during download read"));
      Eio.Switch.on_release sw (fun () -> Lane.install_automation_executor None);
      let execution = Masc.Keeper_tool_in_process_runtime.handle_browser_read_with_outcome
          ~config ~meta ~args:(`Assoc ["lane",`String "automation";"mode",`String "downloads";"tabId",`Int 1]) in
      check bool "browser read completes" true (execution.disposition = Tool_result.Completed ());
      let result = Tool_result.make_ok ~tool_name:"BrowserRead" ~start_time:0.0
          ?data:execution.data ?metadata:execution.metadata () in
      let output = match Masc.Tool_bridge.to_agent_core_typed_result ~base_path:config.base_path result with
        | Ok output -> output | Error error -> fail error.message in
      let reference = match Tool_output.decode_from_agent_core output.content with
        | Tool_output.Decoded reference -> reference
        | Tool_output.Not_marker | Tool_output.Invalid_marker _ -> fail "provider did not receive a durable result manifest" in
      let stored = match Tool_blob_store.fetch (Tool_blob_store.create ~base_path:config.base_path) ~sha256:reference.sha256 with
        | Ok (Some bytes) -> bytes | Ok None -> fail "manifest missing"
        | Error error -> fail (Tool_blob_store.fetch_error_to_string error) in
      check bool "binary download manifest is valid UTF-8 JSON" true (String.is_valid_utf_8 stored);
      match Tool_output.artifact_manifest_of_json (Yojson.Safe.from_string stored) with
      | Tool_output.Decoded_artifact_manifest {structured_content;artifact_refs;_} ->
        check bool "download identity and reader survive" true (structured_content = payload);
        (match artifact_refs with
         | [file] ->
           (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path:config.base_path) ~sha256:file.sha256 with
            | Ok (Some actual) -> check string "referenced bytes remain exact" bytes actual
            | Ok None -> fail "download artifact missing"
            | Error error -> fail (Tool_blob_store.fetch_error_to_string error))
         | _ -> fail "expected exactly one downloadable file")
      | Tool_output.Not_artifact_manifest | Tool_output.Invalid_artifact_manifest _ -> fail "invalid durable download manifest")))

let test_interact_production_failure_phase () =
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let invoke args = Masc.Keeper_tool_in_process_runtime.handle_browser_interact_with_outcome ~args in
    let args = `Assoc ["lane",`String "automation";"tabId",`Int 1;
      "action",`String "click";"selector",`String "a";"expectedUrl",`String "https://example.org"] in
    let phase result = result.Masc.Keeper_tool_execution.failure_effect_disposition in
    check bool "invalid input is recoverable in production wrapper" true
      (phase (invoke (`Assoc [])) = Tool_result.Proven_pre_effect);
    check bool "disconnected selected client rejects before execution" true
      (phase (invoke (`Assoc ["lane",`String "live";"tabId",`Int 1;
        "clientId",`String "00000000-0000-4000-8000-000000000001";
        "action",`String "click";"selector",`String "a"])) = Tool_result.Proven_pre_effect);
    let reply = ref (Lane.Rejected_before_effect "observed document changed") in
    Lane.install_automation_executor (Some (fun _ -> !reply));
    Eio.Switch.on_release sw (fun () -> Lane.install_automation_executor None);
    check bool "typed backend pre-effect rejection is recoverable" true
      (phase (invoke args) = Tool_result.Proven_pre_effect);
    reply := Lane.Answered (`Assoc ["ok",`Bool false;"error",`String "observed node detached";
      "effectPhase",`String "not_started"]);
    check bool "structured native pre-effect receipt is recoverable" true
      (phase (invoke args) = Tool_result.Proven_pre_effect);
    reply := Lane.Refused "response lost after click";
    check bool "post-dispatch uncertainty remains fenced" true
      (phase (invoke args) = Tool_result.Effect_outcome_unknown);
    reply := Lane.Answered (`Assoc ["ok",`Bool false;"error",`String "observed node detached"]);
    check bool "error wording alone never establishes pre-effect" true
      (phase (invoke args) = Tool_result.Effect_outcome_unknown)))

let () = run "Firefox controls" ["behavior",[
  test_case "production interact preserves failure phase" `Quick test_interact_production_failure_phase;
  test_case "download result reaches provider manifest" `Quick test_download_result_reaches_provider;
  test_case "navigation uses requested tab" `Quick test_targeted_goto;
  test_case "selectors must match exactly once" `Quick test_selector_contract;
  test_case "fill and press use native input" `Quick test_native_fill_and_key;
  test_case "parallel interactions keep their tab" `Quick test_parallel_targeting;
  test_case "stale ids cannot target a new session" `Quick test_stale_session_id;
  test_case "pre-effect failures permit correction" `Quick test_pre_effect_tool_outcome;
  test_case "owned uploads use exact private snapshots" `Quick test_owned_upload_staging;
  test_case "upload files follow confirmed session lifetime" `Quick test_upload_lease_failures;
  test_case "cancelled selection retains session-owned snapshots" `Quick test_upload_lease_cancellation;
  test_case "context and file arguments are explicit" `Quick test_context_arguments;
  test_case "arguments are parsed before effects" `Quick test_parser]]
