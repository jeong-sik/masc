(** Native launcher/MCP -> declaration-owned host cycle -> real HTTP exact
    runner -> retained final -> same worker. Only the provider is loopback. *)
open Alcotest
open Masc
module R = Lane_addon_runtime
module F = Exact_output_fixture
let launcher=ref ""
let ok = function Ok value -> value | Error detail -> fail detail
let member=Yojson.Safe.Util.member
let text key value=member key value |> Yojson.Safe.Util.to_string
let write path bytes=Fs_compat.mkdir_p (Filename.dirname path);Out_channel.with_open_bin path (fun out -> output_string out bytes)
let worker={|import json,os,sys
root=sys.argv[1]
pending={"kind":"exact_output","request_id":"native-plan-1","output":"plan","system":"Return one browser plan.","messages":["Inspect the current page."]}
for line in sys.stdin:
    req=json.loads(line)
    if "id" not in req: continue
    method=req["method"]
    if method=="initialize": result={"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"native-exact-fixture","version":"1"}}
    elif method=="tools/list": result={"tools":[{"name":name,"inputSchema":{"type":"object"}} for name in ["lane_observe","lane_host_requests","lane_host_result"]]}
    elif method=="tools/call":
        name=req["params"]["name"]
        if name=="lane_observe":
            open(os.path.join(root,"observed."+str(os.getpid())),"w").close()
            value={"rows":[],"coverage":[]}
        elif name=="lane_host_requests": value={"requests":[] if pending is None else [pending]}
        elif name=="lane_host_result":
            args=req["params"]["arguments"]
            assert args["request_id"]=="native-plan-1"
            path=os.path.join(root,"received."+str(os.getpid()))
            with open(path+".tmp","w") as out: json.dump(args,out)
            os.replace(path+".tmp",path)
            pending=None;value={"accepted":True}
        else: raise RuntimeError(name)
        result={"content":[],"structuredContent":value}
    else: raise RuntimeError(method)
    print(json.dumps({"jsonrpc":"2.0","id":req["id"],"result":result}),flush=True)
|}
let scenario () =
  let root=Filename.temp_dir "native-exact-cycle-" "" |> Unix.realpath in
  let config_root=Filename.concat root ".masc/config" in
  let bin=Filename.concat root "bin" in Unix.mkdir bin 0o700;
  Unix.symlink !launcher (Filename.concat bin "masc-native-addon-launcher");
  let search=bin ^ ":" ^ Option.value ~default:"" (Sys.getenv_opt "PATH") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    Masc_test_deps.with_process_env "PATH" (Some search) (fun () ->
    Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some root) (fun () ->
    Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some config_root) (fun () ->
    Masc_test_deps.with_process_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" (Some "true") (fun () ->
    F.with_official_client_runtimes (fun () -> Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock=Eio.Stdenv.clock env and net=Eio.Stdenv.net env in
      Eio_context.with_test_env ~sw ~clock ~net ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
        R.For_testing.reset ();
        let answer=`Assoc ["action",`String "inspect"] in
        let server=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response answer)) in
        let lane=Runtime_schema.addon_lane ~declaration_id:"native" ~output:"plan" |> ok in
        ignore (F.publish_registry ~lane_id:(Runtime_schema.exact_lane_key (Runtime_schema.Addon lane))
          ~slot_ids:["loopback"] (F.resolver_snapshot ~source:root [{F.id="loopback";base_url=server.base_url}]));
        R.register_exact_runner (Server_lane_addon_exact.runner ~base_path:root);
        let config=Workspace.default_config root in
        let script=Filename.concat root "worker.py" and manifest=Filename.concat root "package.toml" in
        write script worker;
        write manifest (Printf.sprintf {|id="native-exact"
revision="1"
title="Native exact-output fixture"
runtime="host_process"
command=["python3",%S,%S]
contributions=["observe"]
[resources]
max_reply_bytes=65536
[world.exact_outputs.plan]
schema="plan.json"
|} script root);
        write (Filename.concat root "plan.json") {|{"type":"object","properties":{"action":{"type":"string"}},"required":["action"],"additionalProperties":false}|};
        let directory=Filename.concat config_root "lane-addons" in
        let declaration=Filename.concat directory "native.toml" in
        Fs_compat.mkdir_p directory;
        R.start_configuration_service ~config ~sw ~clock;
        let configure selected = write declaration (Printf.sprintf {|id="native"
run_id="native-world"
manifest_path=%S
exact_outputs=%s
[binding]
sources=[]
|} manifest (if selected then "[\"plan\"]" else "[]"));
          ignore (R.reconcile_configuration ~config ~directory |> ok) in
        let instances ()=R.dispatch ~access:Lane_addon_sources.Operator_configuration ~config
          ~operation:R.Inspect (`Assoc []) |> Result.map_error R.error_to_string |> ok
          |> member "instances" |> Yojson.Safe.Util.to_list in
        let current ()=instances () |> List.find_opt (fun item ->
          member "id" (member "configuration" item)=`String "native" && text "kind" (member "phase" item)<>"detached") in
        let path prefix item=match member "resource" item with
          | `Null -> None
          | resource ->
              (match Lane_addon_lifecycle.resource_of_json resource |> ok with
               | Native_resource {pid;_} -> Some (Filename.concat root (prefix ^ string_of_int pid))
               | Container_resource _ -> fail "expected the native fixture worker") in
        let await predicate=F.await_within_fixture_budget ~clock ~failure:"native host cycle did not settle"
          (let result,resolve=Eio.Promise.create () in
           Eio.Switch.check sw;
           Eio.Fiber.fork ~sw (fun () -> let rec loop ()=if predicate () then Eio.Promise.resolve resolve ()
             else (Eio.Time.sleep clock 0.001;loop ()) in loop ());result) in
        let ready prefix = match current () with
          | None -> false | Some item -> Option.exists Sys.file_exists (path prefix item) in
        configure true;
        await (fun () -> ready "received.");
        let first=Option.get (current ()) in
        let first_id=text "instance_id" first in
        let delivered=Yojson.Safe.from_file (Option.get (path "received." first)) |> member "result" in
        check string "provider answer is final" "answered" (text "status" delivered);
        check bool "structured output reaches original worker" true (member "output" delivered=answer);
        check int "one provider call" 1 (F.post_count server);
        configure false;
        await (fun () -> match current () with Some item -> text "instance_id" item<>first_id && ready "observed." | None -> false);
        check int "independent output selection disables model I/O" 1 (F.post_count server);
        let disabled_id=text "instance_id" (Option.get (current ())) in
        configure true;
        await (fun () -> match current () with Some item -> text "instance_id" item<>disabled_id && ready "received." | None -> false);
        check int "retained answer reaches replacement without a new call" 1 (F.post_count server);
        Sys.remove declaration;ignore (R.reconcile_configuration ~config ~directory |> ok);
        await (fun () -> current ()=None))))))))))
let () =
  if Array.length Sys.argv<>2 then fail "expected native launcher path";
  launcher:=Unix.realpath Sys.argv.(1);
  Mirage_crypto_rng_unix.use_default ();
  run ~argv:[|Sys.argv.(0)|] "native exact-output broker" ["integration",[
    test_case "provider, private result, selection and retained reattachment" `Quick scenario]]
