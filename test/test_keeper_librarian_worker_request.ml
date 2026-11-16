open Alcotest
open Masc
module Wire = Keeper_librarian_worker_request
module Exact = Lane_addon_exact
module Hooks = Lane_addon_tool_hooks
let get = function Ok value -> value | Error detail -> fail detail
let member = Yojson.Safe.Util.member
let json = testable Yojson.Safe.pp (fun left right ->
  get (Lane_addon_action.canonical left) = get (Lane_addon_action.canonical right))
let request id text = get (Exact.request_of_json (`Assoc ["kind",`String "exact_output";
  "request_id",`String id;"output",`String "durable";
  "messages",`List [`Assoc ["role",`String "user";"text",`String text]];
  "schema",`Assoc ["type",`String "object";"additionalProperties",`Bool true;
    "properties",`Assoc ["count",`Assoc ["type",`String "integer";"minimum",`Int 0]]]]))
let submit request = `Assoc ["kind",`String "submit";"request",Exact.request_to_json request]
let prepare ~max_reply_bytes request =
  Wire.prepare ~max_reply_bytes ~request_id:request.Exact.request_id ~tool:"derive_memory"
    ~arguments:(submit request) |> get
let operation name arguments = `Assoc ["method",`String "tools/call";
  "params",`Assoc ["name",`String name;"arguments",arguments]]
let admitted arguments = operation "lane_call" (`Assoc ["tool",`String "derive_memory";
  "arguments",arguments;"caller",`Assoc ["kind",`String "operator"]])

let scenario run () =
  let base = Filename.temp_dir "librarian-worker-request-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
  Eio_main.run (fun env ->
    Process_eio.init ~cwd_default:(Eio.Stdenv.cwd env)
      ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
    Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
      let package = Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
        |> Result.map_error Lane_addon_manifest.error_to_string |> get in
      let rpc operation =
        let input = [`Assoc ["method",`String "initialize";"params",`Assoc []];operation]
          |> List.mapi (fun i operation ->
            let fields = Yojson.Safe.Util.to_assoc operation in
            Yojson.Safe.to_string (`Assoc (["jsonrpc",`String "2.0";"id",`Int (i+1)] @ fields)))
          |> String.concat "\n" in
        let status,stdout,stderr = Process_eio.run_argv_with_stdin_and_status_split
          ~stdin_content:(input ^ "\n")
          ["python3";Filename.concat package.directory "server.py";"--state";base] in
        (match status with
         | Unix.WEXITED 0 -> ()
         | Unix.WEXITED code -> failf "worker exit %d: %s" code stderr
         | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> failf "worker signal %d" signal);
        check string "worker stderr" "" stderr;
        match String.split_on_char '\n' stdout |> List.filter (fun line -> line <> "") with
        | [_;reply] -> member "result" (Yojson.Safe.from_string reply)
        | _ -> fail "worker must reply to initialization and this operation" in
      let tools = rpc (`Assoc ["method",`String "tools/list"]) |> member "tools"
        |> Yojson.Safe.Util.to_list |> List.map (fun value ->
          Mcp_protocol.Mcp_types.tool_of_yojson value |> get) in
      let tool = List.find (fun (tool : Mcp_protocol.Mcp_types.tool) -> tool.name="derive_memory") tools in
      let hooks = Hooks.prepare ~hooks:package.tool_hooks tool |> get in
      let invoke arguments =
        get (Hooks.before_call hooks arguments);
        let reply = rpc (admitted arguments) |> Mcp_protocol.Mcp_types.tool_result_of_yojson |> get in
        get (Hooks.after_call hooks reply);
        check bool "worker accepted the command" false (reply.is_error=Some true);
        match reply.structured_content with Some result -> result | None -> fail "worker state is absent" in
      run ~base ~package ~rpc ~invoke)))

let oversized ~base ~package ~rpc ~invoke =
  let max_reply_bytes = Lane_addon_types.max_reply_bytes package in
  let original = request "oversized-original" (String.make (max_reply_bytes+1) 'x' ^ " 한글 🌊\n\\\"") in
  let command = prepare ~max_reply_bytes original in
  check bool "the body stays outside the worker frame" true
    (String.length (Yojson.Safe.to_string command) < max_reply_bytes);
  let terminal = invoke command in
  check json "a real body refusal is retained" (`Assoc ["status",`String "input_refused";
    "kind",`String "request_body_refused"]) (member "result" terminal);
  let read = `Assoc ["kind",`String "read";"request_id",`String original.request_id] in
  check json "a fresh process reads the same terminal" terminal (invoke read);
  let files = Sys.readdir (Filename.concat base "keeper-librarian") |> Array.to_list in
  (match files with
   | [name] ->
     let record = Yojson.Safe.from_file (Filename.concat (Filename.concat base "keeper-librarian") name) in
     check json "the refused full body is never retained by the worker" `Null (member "request" record)
   | _ -> fail "one original owns one terminal");
  let next = request "following-original" "The same lane can retain the next request." in
  check json "another original is pending" (`String "pending")
    (member "state" (invoke (prepare ~max_reply_bytes next)));
  let listing = rpc (operation "lane_host_requests" (`Assoc [])) |> member "structuredContent" in
  check json "only the following request is listed" (`List [Exact.request_to_json next])
    (member "requests" listing)

let preserves_original ~base:_ ~package:_ ~rpc ~invoke =
  let original = request "pending-original" "원본 🌊\n\\\" order and identity" in
  let pending = invoke (submit original) in
  let compact = prepare ~max_reply_bytes:1 original in
  check json "host and worker canonical digests agree; pending stays pending" pending (invoke compact);
  let final = `Assoc ["status",`String "outcome_unknown"] in
  ignore (rpc (operation "lane_host_result" (`Assoc ["request_id",`String original.request_id;"result",final])));
  check json "an unknown result remains authoritative after restart" final
    (member "result" (invoke compact))

let refuses_unconfirmed_wire () =
  let original = request "original" "Original evidence" in
  check bool "wrong captured identity is refused" true (Result.is_error
    (Wire.prepare ~max_reply_bytes:1 ~request_id:"different" ~tool:"derive_memory" ~arguments:(submit original)));
  check bool "wrong tool cannot bypass purpose validation" true (Result.is_error
    (Wire.prepare ~max_reply_bytes:1 ~request_id:original.request_id ~tool:"admit_memory" ~arguments:(submit original)));
  let fields = Exact.request_to_json original |> Yojson.Safe.Util.to_assoc in
  let floating = get (Exact.request_of_json (`Assoc (("schema",`Assoc ["type",`String "object";
    "minimum",`Float 9.577158879848941e-245]) :: List.remove_assoc "schema" fields))) in
  check bool "unconfirmed cross-language float digest is refused locally" true (Result.is_error
    (Wire.prepare ~max_reply_bytes:1 ~request_id:floating.request_id ~tool:"derive_memory" ~arguments:(submit floating)));
  let bytes = String.length (Yojson.Safe.to_string (Exact.request_to_json original)) in
  check json "the exact byte boundary still uses the worker envelope check" (submit original)
    (prepare ~max_reply_bytes:bytes original)

let () = run "Librarian captured worker requests" ["real worker",[
  test_case "oversized original refuses without starving the next original" `Quick (scenario oversized);
  test_case "existing pending and unknown outcomes survive compact observation" `Quick (scenario preserves_original)];
  "host authority",[test_case "unconfirmed identity, purpose and digest are not dispatched" `Quick refuses_unconfirmed_wire]]
