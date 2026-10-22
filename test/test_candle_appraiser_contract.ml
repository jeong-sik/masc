(** The real package and MCP descriptors pass the host's own schema and Hook
    validators. Model responses remain scripted; no provider or ledger runs. *)
open Alcotest
open Masc
module Json = Yojson.Safe.Util
module Hooks = Lane_addon_tool_hooks
let member = Json.member
let unwrap = function Ok value -> value | Error detail -> fail detail
let call name arguments = `Assoc ["method", `String "tools/call";
  "params", `Assoc ["name", `String name; "arguments", arguments]]
let admitted arguments = call "lane_call" (`Assoc ["tool", `String "candle_appraise";
  "arguments", arguments; "caller", `Assoc ["kind", `String "operator"]])
let intent =
  let grade = match Candle_grade.of_string "medium" with
    | Some grade -> grade | None -> fail "the fixture grade is invalid" in
  Candle_appraisal_intent.make
    ~identity:{Candle_appraisal.goal_id="goal-original";
      request_id="payout-original";verification_run_id="proof-original"}
    ~prompt:"Judge only the captured goal."
    (Candle_appraisal.Grade {goal={title="Original goal";metric=None;target_value=None};
      grades=[grade,"Connected feature"]}) |> unwrap
let submit = Candle_appraisal_intent.submit_arguments intent
let read = Candle_appraisal_intent.read_arguments intent
let answer = `Assoc ["status", `String "answered";
  "output", `Assoc ["grade", `String "medium"]; "slot", `String "scripted-original"]

let test_real_package_contract () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
    let package = Lane_addon_manifest.load ~path:"../addons/candle-appraiser/lane.toml"
      |> Result.map_error Lane_addon_manifest.error_to_string |> unwrap in
    let state = Filename.temp_dir "candle-host-contract-" "" in
    Fun.protect ~finally:(fun () -> Fs_compat.remove_tree state) (fun () ->
      let operations = [
        `Assoc ["method", `String "initialize"; "params", `Assoc []];
        `Assoc ["method", `String "tools/list"];
        admitted submit; call "lane_host_requests" (`Assoc []);
        call "lane_host_result" (`Assoc ["request_id", `String (Candle_appraisal_intent.request_id intent); "result", answer]);
        admitted read; call "lane_host_requests" (`Assoc [])] in
      let stdin_content = List.mapi (fun index operation ->
        let fields = Json.to_assoc operation in
        Yojson.Safe.to_string (`Assoc (["jsonrpc", `String "2.0";
          "id", `Int (index + 1)] @ fields))) operations |> String.concat "\n" in
      let status, stdout, stderr = Process_eio.run_argv_with_stdin_and_status_split
        ~stdin_content:(stdin_content ^ "\n")
        ["python3"; Filename.concat package.directory "server.py"; "--state"; state] in
      (match status with Unix.WEXITED 0 -> ()
        | Unix.WEXITED code -> failf "worker exited %d: %s" code stderr
        | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> failf "worker signal %d" signal);
      check string "no worker diagnostics" "" stderr;
      let replies = String.split_on_char '\n' stdout |> List.filter (fun s -> s <> "")
        |> List.map Yojson.Safe.from_string in
      let result index = member "result" (List.nth replies index) in
      let tools = member "tools" (result 1) |> Json.to_list
        |> List.map (fun raw -> Mcp_protocol.Mcp_types.tool_of_yojson raw |> unwrap) in
      let tool = match List.find_opt (fun (tool : Mcp_protocol.Mcp_types.tool) ->
        tool.name = "candle_appraise") tools with
        | Some tool -> tool | None -> fail "the real worker did not advertise its tool" in
      let hooks = Hooks.prepare ~hooks:package.tool_hooks tool |> unwrap in
      ignore (Hooks.before_call hooks submit |> unwrap);
      ignore (Hooks.before_call hooks read |> unwrap);
      List.iter (fun index ->
        let raw = result index in
        let reply = {(Mcp_protocol.Mcp_types.tool_result_of_text "actual worker response") with
          is_error = Some (member "isError" raw |> Json.to_bool);
          structured_content = Some (member "structuredContent" raw)} in
        check bool "the worker answered successfully" false (reply.is_error = Some true);
        ignore (Hooks.after_call hooks reply |> unwrap)) [2; 5];
      let pending = member "structuredContent" (result 3) |> member "requests" |> Json.to_list in
      (match pending with
       | [pending] ->
         let request = Lane_addon_exact.request_of_json pending |> unwrap in
         let output = List.find (fun (output : Lane_addon_types.exact_output) ->
           output.name = "grade") package.exact_outputs in
         ignore (Lane_addon_exact.schema_for_request ~output request |> unwrap);
         ignore (Lane_addon_exact.validate_answer ~output request (member "output" answer) |> unwrap)
       | _ -> fail "the original request must remain listed until terminal delivery");
      ignore (Candle_appraisal.decode (Candle_appraisal_intent.request intent)
        (member "output" answer) |> unwrap);
      check bool "the terminal answer is no longer dispatched" true
        (member "requests" (member "structuredContent" (result 6)) = `List [])))

(* Restart the real stdio process at every RPC. The production server consumer
   must recover the same disk-backed intent; only provider judgment is scripted. *)
let test_real_worker_resumes_the_server_consumer () =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:(fun () -> Process_eio.reset_for_testing (); Fs_compat.clear_fs ()) (fun () ->
    let package = Lane_addon_manifest.load ~path:"../addons/candle-appraiser/lane.toml"
      |> Result.map_error Lane_addon_manifest.error_to_string |> unwrap in
    let base_path = Filename.temp_dir "candle-server-worker-" "" in
    Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
      let state = Filename.concat base_path "worker" in
      Fs_compat.mkdir_p state;
      let rpc operation =
        let input = `Assoc (["jsonrpc", `String "2.0"; "id", `Int 1] @ Json.to_assoc operation)
          |> Yojson.Safe.to_string in
        let status, stdout, stderr = Process_eio.run_argv_with_stdin_and_status_split
          ~stdin_content:(input ^ "\n")
          ["python3"; Filename.concat package.directory "server.py"; "--state"; state] in
        (match status with Unix.WEXITED 0 -> ()
         | Unix.WEXITED code -> failf "worker exited %d: %s" code stderr
         | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> failf "worker signal %d" signal);
        check string "no worker diagnostics" "" stderr;
        Json.member "result" (Yojson.Safe.from_string (String.trim stdout)) in
      let tool = rpc (`Assoc ["method", `String "tools/list"])
        |> member "tools" |> Json.to_list
        |> List.map (fun raw -> Mcp_protocol.Mcp_types.tool_of_yojson raw |> unwrap)
        |> List.find (fun (tool : Mcp_protocol.Mcp_types.tool) -> tool.name = "candle_appraise") in
      let hooks = Hooks.prepare ~hooks:package.tool_hooks tool |> unwrap in
      let submitted = ref 0 in
      let port ~arguments =
        ignore (Hooks.before_call hooks arguments |> unwrap);
        if Json.(member "kind" arguments = `String "submit") then incr submitted;
        let reply = rpc (admitted arguments) |> Mcp_protocol.Mcp_types.tool_result_of_yojson |> unwrap in
        ignore (Hooks.after_call hooks reply |> unwrap);
        Ok reply in
      Prompt_defaults.init ();
      Prompt_registry.set_markdown_dir "../config/prompts";
      let registry_path = Filename.concat base_path "runs.jsonl" in
      let registry = Exact_lane_run_registry.create ~path:registry_path () in
      let identity : Candle_appraisal.identity = {goal_id="server-original";request_id="payout-original";
        verification_run_id="proof-original"} in
      let request = Candle_appraisal_intent.request intent in
      let store = Lane_addon_store.create ~root:(Filename.concat base_path "request-ownership") in
      let retain ~request_id ~request = Lane_addon_tool_request_owner.retain ~store
        ~scope:"candle-appraisals" ~request_id ~installation_id:"original-installation"
        ~package_id:package.id ~tool:"candle_appraise" ~request
        |> Result.map_error (fun error -> Lane_addon_runtime.Unavailable (Lane_addon_tool_request_owner.error_to_string error)) in
      let run registry = Server_candle_appraiser.For_testing.run ~registry ~base_path ~retain ~call:port ~identity request in
      (match run registry with
       | Error (Candle_appraisal.Transport_unavailable _) -> ()
       | Ok _ | Error (Candle_appraisal.Invalid_response _ | Candle_appraisal.Execution_rejected _) ->
         fail "the real worker must retain pending before host delivery");
      let listed = rpc (call "lane_host_requests" (`Assoc []))
        |> member "structuredContent" |> member "requests" |> Json.to_list in
      let original = match listed with
        | [original] -> Lane_addon_exact.request_of_json original |> unwrap
        | _ -> fail "exactly the original Grade must be pending" in
      let output = List.find (fun (output : Lane_addon_types.exact_output) -> output.name = "grade") package.exact_outputs in
      let checked = Lane_addon_exact.validate_answer ~output original (member "output" answer) |> unwrap in
      let final = Lane_addon_exact.Call_final (Lane_addon_exact.Answered {
        output=checked;slot="scripted-original";usage=None}) in
      let delivered = rpc (call "lane_host_result" (`Assoc ["request_id", `String original.request_id;
        "result", Lane_addon_exact.final_to_json final])) in
      check bool "host result is retained" true Json.(to_bool (member "accepted" (member "structuredContent" delivered)));
      let returned = match run (Exact_lane_run_registry.replay registry_path) with
        | Ok returned -> returned | Error error -> fail (Candle_appraisal.error_to_string error) in
      check string "consumer trace retains the original intent" original.request_id returned.trace.run_id;
      check string "consumer trace retains the actual slot" "scripted-original" returned.trace.slot_id;
      check int "worker restarts do not cause a second submit" 1 !submitted;
      let listed = rpc (call "lane_host_requests" (`Assoc [])) |> member "structuredContent" |> member "requests" in
      check bool "terminal original is not dispatched again" true (listed = `List [])))

let () = run "Candle actual package/host contract"
  ["contract", [
    test_case "manifest, advertised Hooks and retained answer" `Quick test_real_package_contract;
    test_case "real worker restarts resume the production consumer" `Quick test_real_worker_resumes_the_server_consumer]]
