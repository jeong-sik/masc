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
let original = `Assoc [
  "request_id", `String "grade-original";
  "identity", `Assoc ["goal_id", `String "goal-original";
    "request_id", `String "payout-original"; "verification_run_id", `String "proof-original"];
  "stage", `String "grade"; "input", `Assoc ["goal", `Assoc ["title", `String "Original goal"]];
  "schema", `Assoc ["type", `String "object";
    "properties", `Assoc ["grade", `Assoc ["type", `String "string"; "enum", `List [`String "A"]]];
    "required", `List [`String "grade"]; "additionalProperties", `Bool false];
  "prompt", `String "Judge only the captured goal."]
let submit = `Assoc ["kind", `String "submit"; "request", original]
let read = `Assoc ["kind", `String "read"; "request_id", `String "grade-original"]
let answer = `Assoc ["status", `String "answered";
  "output", `Assoc ["grade", `String "A"]; "slot", `String "scripted-original"]

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
        call "lane_host_result" (`Assoc ["request_id", `String "grade-original"; "result", answer]);
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
      check bool "the terminal answer is no longer dispatched" true
        (member "requests" (member "structuredContent" (result 6)) = `List [])))

let () = run "Candle actual package/host contract"
  ["contract", [test_case "manifest, advertised Hooks and retained answer" `Quick test_real_package_contract]]
