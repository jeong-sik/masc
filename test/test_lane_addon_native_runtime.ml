(** Real default-backend installation, MCP action and retained cleanup. No
    browser profile, external service or fake Runtime backend is involved. *)
open Alcotest
open Masc
module R = Lane_addon_runtime
let launcher = ref ""
let member = Yojson.Safe.Util.member
let text key json = member key json |> Yojson.Safe.Util.to_string
let require = function Ok value -> value | Error message -> fail message
let dispatch config operation fields =
  R.dispatch ~caller:"native-runtime-tester" ~access:Lane_addon_sources.Operator_configuration
    ~config ~operation (`Assoc fields) |> Result.map_error R.error_to_string |> require
let write path value = Out_channel.with_open_bin path (fun out -> output_string out value)
let rec remove path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path
let wait clock predicate =
  let rec loop () = if predicate () then () else (Eio.Time.sleep clock 0.005; loop ()) in loop ()
let server = {|import json,os,sys
root=sys.argv[1]
schema={"type":"object","properties":{"context":{"type":"object"},"request_id":{"type":"string"},"action":{"type":"object"}},"required":["context","request_id","action"]}
with open(os.path.join(root,"spawned"),"w") as out: out.write(str(os.getpid()))
for line in sys.stdin:
    req=json.loads(line)
    if "id" not in req: continue
    method=req["method"]
    if method=="initialize":
        result={"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"native-runtime-fixture","version":"1"}}
    elif method=="tools/list":
        result={"tools":[{"name":"lane_observe","inputSchema":{"type":"object"}},{"name":"lane_act","inputSchema":schema}]}
    elif method=="tools/call":
        name=req["params"]["name"]
        value={"rows":[],"coverage":[]}
        if name=="lane_act":
            with open(os.path.join(root,"effects"),"a") as out: out.write(req["params"]["arguments"]["request_id"]+"\n")
            value={"status":"confirmed","result":{"applied":True},"output":value}
        result={"content":[],"structuredContent":value}
    else: raise RuntimeError(method)
    print(json.dumps({"jsonrpc":"2.0","id":req["id"],"result":result}),flush=True)
|}
let with_fixture run =
  let root = Filename.temp_dir "native-runtime-" "" in
  let previous = Sys.getenv_opt "PATH" in
  let bin = Filename.concat root "bin" in Unix.mkdir bin 0o700;
  Unix.symlink !launcher (Filename.concat bin "masc-native-addon-launcher");
  Unix.putenv "PATH" (bin ^ ":" ^ Option.value ~default:"" previous);
  Fun.protect ~finally:(fun () ->
    (match previous with Some value -> Unix.putenv "PATH" value | None -> Unix.unsetenv "PATH");
    remove root) (fun () -> Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let clock = Eio.Stdenv.clock env in
    Eio.Time.with_timeout_exn clock 15. (fun () -> Eio.Switch.run (fun sw ->
      Eio_context.with_test_env ~sw ~clock ~net:(Eio.Stdenv.net env)
        ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
        R.For_testing.reset (); run clock root (Workspace.default_config root))))))
let native_installation_with_slot seed_slot () = with_fixture (fun clock root config ->
  let script = Filename.concat root "worker.py" in write script server;
  let manifest = Filename.concat root "native.toml" in
  write manifest (Printf.sprintf {|id = "native-runtime"
revision = "fixture-1"
title = "Native runtime fixture"
runtime = "host_process"
command = ["python3", %S, %S]
contributions = ["observe", "act"]
[resources]
max_reply_bytes = 65536
[world.actions]
tool = "lane_act"
|} script root);
  let attach () = dispatch config R.Attach ["manifest_path",`String manifest;
    "run_id",`String "native-world";"binding",`Assoc ["sources",`List []]] |> text "instance_id" in
  let inspect id = dispatch config R.Inspect ["instance_id",`String id]
    |> member "instances" |> Yojson.Safe.Util.to_list |> List.hd in
  let detached id = let item = inspect id in
    text "kind" (member "phase" item)="detached" && text "runtime_presence" item="retained" in
  let ready id = (inspect id |> member "observation_seq" |> Yojson.Safe.Util.to_int)>0 in
  let id = attach () in wait clock (fun () -> ready id);
  let captured = inspect id in
  check string "durable admission is native" "host_process"
    (captured |> member "execution_authority" |> text "kind");
  let pid = captured |> member "resource" |> member "pid" |> Yojson.Safe.Util.to_int in
  check int "resource identifies actual payload" pid
    (In_channel.with_open_bin (Filename.concat root "spawned") In_channel.input_all |> int_of_string);
  let action = ["instance_id",`String id;"expected_incarnation",`String id;
    "request_id",`String "once";"action",`Assoc []] in
  ignore (dispatch config R.Act action);
  let receipt () = dispatch config R.Action_status ["instance_id",`String id;"request_id",`String "once"] in
  wait clock (fun () -> text "state" (receipt ())="confirmed");
  check int "action receipt identifies actual native executor" pid
    (receipt () |> member "executor" |> member "pid" |> Yojson.Safe.Util.to_int);
  ignore (dispatch config R.Act action);
  check string "duplicate request has one actual effect" "once\n"
    (In_channel.with_open_bin (Filename.concat root "effects") In_channel.input_all);
  ignore (dispatch config R.Detach ["instance_id",`String id]);
  wait clock (fun () -> detached id);
  check bool "native foreground group is absent before release" false
    (Posix_spawn_detached.group_id_has_members pid);
  check string "release is native" "native_released"
    (inspect id |> member "lifecycle" |> member "release" |> text "kind");
  (* A captured pre-detach binding is replayed only after its actual worker has
     settled. Recovery uses its old admission, never a replacement process. *)
  R.For_testing.reset ();
  let store = Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  require (Lane_addon_store.save_binding store ~instance_id:id captured);
  ignore (dispatch config R.Detach ["instance_id",`String id]);
  wait clock (fun () -> detached id);
  check string "retained recovery confirms the exact old incarnation" id
    (inspect id |> member "lifecycle" |> member "release" |> text "instance_id");
  let replacement = attach () in wait clock (fun () -> ready replacement);
  check bool "reattach has a fresh incarnation" true (replacement<>id);
  ignore (dispatch config R.Detach ["instance_id",`String replacement]);
  wait clock (fun () -> detached replacement);
  let directory = Filename.concat root "declarations" in Unix.mkdir directory 0o700;
  let declaration = Filename.concat directory "configured.toml" in
  let configure enabled = write declaration (Printf.sprintf {|id = "configured-native"
enabled = %b
run_id = "native-world"
manifest_path = %S
[binding]
sources = []
|} enabled manifest) in
  let reconcile () = ignore (require (R.reconcile_configuration ~config ~directory)) in
  let configured () = dispatch config R.Inspect [] |> member "instances" |> Yojson.Safe.Util.to_list
    |> List.find_opt (fun item -> match member "configuration" item with
      | `Assoc fields -> List.assoc_opt "id" fields=Some (`String "configured-native")
          && text "kind" (member "phase" item)<>"detached"
      | _ -> false) in
  let slot = Filename.concat (Filename.concat (Lane_addon_store.root store) "native-claims")
    (Lane_addon_store.digest "configured-native") in
  seed_slot slot;
  configure true; reconcile ();
  wait clock (fun () -> Option.exists (fun item -> ready (text "instance_id" item)) (configured ()));
  let first = require (Option.to_result ~none:"configured installation missing" (configured ())) |> text "instance_id" in
  let first_pid = inspect first |> member "resource" |> member "pid" |> Yojson.Safe.Util.to_int in
  configure false; reconcile (); wait clock (fun () -> detached first);
  configure true; reconcile ();
  wait clock (fun () -> Option.exists (fun item -> ready (text "instance_id" item)) (configured ()));
  let second = require (Option.to_result ~none:"replacement installation missing" (configured ())) |> text "instance_id" in
  check bool "configured reattach replaces the incarnation" true (first<>second);
  check bool "prior installation group is gone before slot reuse" false
    (Posix_spawn_detached.group_id_has_members first_pid);
  let claim = Eio_unix.run_in_systhread (fun () -> Native_addon_lease.current ~directories:[slot])
    |> Result.map_error Native_addon_lease.error_to_string |> require in
  check string "same installation slot belongs to the replacement" second (Native_addon_lease.instance_id claim);
  configure false; reconcile (); wait clock (fun () -> detached second))
let native_installation () = native_installation_with_slot (fun _ -> ()) ()
let interrupted_namespace () = native_installation_with_slot (fun directory ->
  match Native_addon_lease.For_testing.prepare ~cleanup_context:None ~directories:[directory] ~instance_id:"unpublished"
      ~sync_ancestry:(fun parent -> raise (Unix.Unix_error (Unix.EIO,"fsync",parent))) with
  | Error _ -> () | Ok _ -> fail "namespace interruption did not occur") ()
let interrupted_metadata () = native_installation_with_slot (fun directory ->
  Unix.mkdir directory 0o700;
  List.iter (fun name ->
    let fd=Unix.openfile (Filename.concat directory name) [Unix.O_CREAT;Unix.O_WRONLY] 0o600 in
    Unix.close fd) ["gate";"lease";"intent.json";"owner.json"]) ()
let interrupted_reservation () = native_installation_with_slot (fun directory ->
  ignore (Native_addon_lease.prepare ~cleanup_context:None ~directories:[directory] ~instance_id:"unpublished"
    |> Result.map_error Native_addon_lease.error_to_string |> require);
  write (Filename.concat directory "intent.json") "") ()
let browser_server = {|import argparse,hashlib,json,os,socket,sys,threading
p=argparse.ArgumentParser()
p.add_argument("root");p.add_argument("mode")
p.add_argument("--socket");p.add_argument("--incarnation");p.add_argument("--max-message-bytes")
a=p.parse_args()
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.bind(a.socket);s.listen()
with open(os.path.join(a.root,"endpoint-"+a.incarnation),"w") as out: out.write(a.socket)
event=threading.Event();payload=None;running=False
def handle(conn):
    global payload,running
    with conn:
        req=json.loads(conn.makefile("rb").readline())
        if req["incarnation"]!=a.incarnation: raise RuntimeError("wrong owner")
        op=req["operation"]
        if op=="snapshot": result={"reply":"receipt"} if a.mode=="bad_ready" or os.path.exists(os.path.join(a.root,"reject-snapshot-"+a.incarnation)) else {"reply":"snapshot","snapshot":{"command_running":running}}
        elif op=="poll": result={"reply":"poll","command":None,"state_id":hashlib.sha256(json.dumps({"command_running":running}).encode()).hexdigest()}
        elif op=="disconnect": result={"reply":"receipt"}
        elif op=="issue":
            event.clear()
            with open(os.path.join(a.root,"issued-"+a.incarnation),"w") as out: out.write("issued")
            event.wait()
            result={"reply":"issue","answer":{"status":"answered","payload":payload}}
        elif op=="deliver":
            payload=req["payload"];event.set();result={"reply":"receipt"}
        else: raise RuntimeError(op)
        conn.sendall((json.dumps(result)+"\n").encode())
def serve():
    while True:
        conn,_=s.accept();threading.Thread(target=handle,args=(conn,),daemon=True).start()
threading.Thread(target=serve,daemon=True).start()
for line in sys.stdin:
    req=json.loads(line)
    if "id" not in req: continue
    method=req["method"]
    if method=="initialize": result={"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"browser-host-fixture","version":"1"}}
    elif method=="tools/list": result={"tools":[{"name":name,"inputSchema":{"type":"object"}} for name in ["lane_observe","lane_call","browser_command"]]}
    elif method=="tools/call":
        if req["params"]["name"]=="lane_call":
            if req["params"]["arguments"]["tool"]!="browser_command": raise RuntimeError("wrong export")
            event.clear();running=True
            with open(os.path.join(a.root,"issued-"+a.incarnation),"w") as out: out.write("issued")
            with open(os.path.join(a.root,"toolcalls-"+a.incarnation),"a") as out: out.write("once\n")
            event.wait();running=False
            result={"content":[],"structuredContent":{"ok":True}}
        else: result={"content":[],"structuredContent":{"rows":[],"coverage":[]}}
    else: raise RuntimeError(method)
    print(json.dumps({"jsonrpc":"2.0","id":req["id"],"result":result}),flush=True)
|}
let browser_installation () = with_fixture (fun clock root config ->
  let script=Filename.concat root "browser.py" in write script browser_server;
  let manifest=Filename.concat root "browser.toml" in
  let install mode = write manifest (Printf.sprintf {|id = "browser-host-fixture"
revision = "fixture-1"
title = "Browser service fixture"
runtime = "host_process"
service = "browser"
command = ["python3", %S, %S, %S]
contributions = ["observe"]
[resources]
max_reply_bytes = 65536
[world.tools]
export = ["browser_command"]
invocation = "host_context"
|} script root mode) in
  let access=Lane_addon_sources.Operator_configuration in
  let inspect id=dispatch config R.Inspect ["instance_id",`String id]
    |> member "instances" |> Yojson.Safe.Util.to_list |> List.hd in
  let services ()=R.browser_services ~config ~access in
  let attach mode=install mode;dispatch config R.Attach ["manifest_path",`String manifest;
    "run_id",`String "browser-host";"binding",`Assoc ["sources",`List []]] |> text "instance_id" in
  let call service command=R.call_browser_service ~config ~access ~service ~command in
  let endpoint id=Filename.concat root ("endpoint-"^id) in
  let issued id=Filename.concat root ("issued-"^id) in
  let socket_path id=In_channel.with_open_bin (endpoint id) In_channel.input_all in
  let unavailable result=match result with Error (Browser_addon_client.Unavailable _) -> true
    | Ok _|Error (Browser_addon_client.Outcome_unknown _) -> false in
  let selected id=wait clock (fun () -> List.exists (fun (service:R.browser_service) -> service.instance_id=id) (services ()));
    List.find (fun (service:R.browser_service) -> service.instance_id=id) (services ()) in
  let id=attach "normal" in
  let original=selected id in
  let pid=inspect id |> member "resource" |> member "pid" |> Yojson.Safe.Util.to_int in
  let client_id=require (Browser_lane.client_id_of_string "0c000000-0000-4000-8000-000000000001") in
  let issue=Browser_addon_wire.Issue {route=Browser_lane.Live_route (Some client_id);verb=Browser_lane.Tabs_list;
    actor=Some "browser-host-tester";timeout_sec=2.;only_if_idle=false} in
  let payload=`Assoc ["ok",`Bool false;"effectPhase",`String "partial";"error",`String "partial result"] in
  let client={Browser_lane.client_id;browser=Firefox;version="158";engine_version="158";transport=Webdriver_bidi} in
  let browser_directory=Filename.concat (Workspace.masc_dir config) Common.browser_lane_dirname in
  Unix.mkdir browser_directory 0o700;
  let poll client=Browser_addon_ingress.poll ~config ~client ~window_sec:0.001 in
  check bool "native ingress registers its first original worker" true (poll client=Ok None);
  let reject_snapshot=Filename.concat root ("reject-snapshot-"^id) in
  write reject_snapshot "reject";
  ignore (dispatch config R.Observe ["instance_id",`String id]);
  wait clock (fun () -> inspect id |> member "phase" |> text "kind"="failed");
  check bool "temporary observation failure does not retire native client" true
    (match poll client with Error (Browser_addon_ingress.Unavailable _) -> true | _ -> false);
  Unix.unlink reject_snapshot;
  ignore (poll client);
  wait clock (fun () -> match R.browser_service_status ~config ~access ~instance_id:id with
    | R.Browser_ready _ -> true | Browser_refresh_needed _|Browser_unavailable|Browser_retired -> false);
  check bool "same native client recovers its original worker" true (poll client=Ok None);
  let export ()=R.tool_exports ~config ~access ~reserved:[] |> require
    |> List.find (fun (item:R.tool_export) -> item.instance_id=id && item.tool.name="browser_command") in
  let export=export () in
  Eio.Fiber.both (fun () ->
    let result=R.call_exported_tool_with_principal ~principal:(Some Lane_addon_call_context.Operator)
      ~config ~access ~reserved:[] ~export ~arguments:(`Assoc []) in
    check bool "long MCP export returns after reverse-channel result" true (Result.is_ok result))
    (fun () ->
      wait clock (fun () -> Sys.file_exists (issued id));
      check bool "native poll wakes running observation beside waiting MCP" true (poll client=Ok None);
      wait clock (fun () -> dispatch config R.Inspect ["instance_id",`String id]
        |> member "rows" |> Yojson.Safe.Util.to_list
        |> List.exists (fun row -> member "command_running" (member "fields" row)=`Bool true));
      check bool "running observation commits before MCP call settles" true
        (call original Browser_addon_wire.Snapshot=Ok (Browser_addon_wire.Snapshot_result (`Assoc ["command_running",`Bool true])));
      write reject_snapshot "reject";
      ignore (dispatch config R.Observe ["instance_id",`String id]);
      wait clock (fun () -> inspect id |> member "phase" |> text "kind"="failed");
      check bool "native result settles original command despite failed observation" true
        (Browser_addon_ingress.deliver ~config ~client ~id:"fixture" ~payload=Ok ()));
  Unix.unlink reject_snapshot;
  ignore (poll client);
  wait clock (fun () -> match R.browser_service_status ~config ~access ~instance_id:id with
    | R.Browser_ready _ -> true | Browser_refresh_needed _|Browser_unavailable|Browser_retired -> false);
  check string "long MCP export dispatched once" "once\n"
    (In_channel.with_open_bin (Filename.concat root ("toolcalls-"^id)) In_channel.input_all);
  Unix.unlink (issued id);
  Eio.Fiber.both (fun () -> check bool "browser result disposition retained" true
    (call original issue=Ok (Browser_addon_wire.Issue_result (Ok (Browser_lane.Answered payload)))))
    (fun () -> wait clock (fun () -> Sys.file_exists (issued id));
      check bool "reverse channel works beside waiting issue" true
        (call original (Browser_addon_wire.Deliver {client_id;id="fixture";payload})=Ok Browser_addon_wire.Receipt));
  ignore (dispatch config R.Detach ["instance_id",`String id]);
  wait clock (fun () -> let item=inspect id in
    text "kind" (member "phase" item)="detached" && text "runtime_presence" item="retained");
  wait clock (fun () -> not (Posix_spawn_detached.group_id_has_members pid));
  check bool "socket absent before release" false (Sys.file_exists (Filename.dirname (socket_path id)));
  check bool "detached handle refused" true (unavailable (call original Browser_addon_wire.Snapshot));
  let replacement=attach "normal" in let next=selected replacement in
  check bool "old handle never resolves replacement" true (unavailable (call original Browser_addon_wire.Snapshot));
  check bool "old native client never polls replacement" true
    (poll client=Error (Browser_addon_ingress.Registration_refused Browser_lane.Client_retired));
  check bool "late native result never reaches replacement" true
    (Browser_addon_ingress.deliver ~config ~client ~id:"fixture" ~payload=
      Error (Browser_addon_ingress.Registration_refused Browser_lane.Client_retired));
  let new_client={client with client_id=require (Browser_lane.client_id_of_string "0c000000-0000-4000-8000-000000000002")} in
  check bool "a fresh native connection can reach the replacement" true (poll new_client=Ok None);
  check bool "replacement has received no replayed command" false (Sys.file_exists (issued replacement));
  let next_pid=inspect replacement |> member "resource" |> member "pid" |> Yojson.Safe.Util.to_int in
  Eio.Fiber.first (fun () -> ignore (call next issue);fail "cancelled issue returned")
    (fun () -> wait clock (fun () -> Sys.file_exists (issued replacement)));
  wait clock (fun () -> not (Posix_spawn_detached.group_id_has_members next_pid));
  wait clock (fun () -> not (Sys.file_exists (Filename.dirname (socket_path replacement))));
  check bool "cancelled issue withdraws original service" true (unavailable (call next Browser_addon_wire.Snapshot));
  let refused=attach "bad_ready" in
  wait clock (fun () -> Sys.file_exists (endpoint refused));
  let failed_pid ()=inspect refused |> member "resource" |> member "pid" in
  wait clock (fun () -> match failed_pid () with `Int pid -> not (Posix_spawn_detached.group_id_has_members pid) | _ -> false);
  wait clock (fun () -> not (Sys.file_exists (Filename.dirname (socket_path refused))));
  check bool "readiness refusal never advertises service" false
    (List.exists (fun (service:R.browser_service) -> service.instance_id=refused) (services ())))
let () =
  if Array.length Sys.argv<>2 then fail "expected native admission launcher path";
  launcher := Unix.realpath Sys.argv.(1);
  run ~argv:[|Sys.argv.(0)|] "lane_addon_native_runtime" ["installation",[
    test_case "actual installation action detach retained recovery reattach" `Quick native_installation;
    test_case "configuration resumes after interrupted slot namespace" `Quick interrupted_namespace;
    test_case "configuration resumes after interrupted slot metadata" `Quick interrupted_metadata;
    test_case "configuration retires unpublished reservation before fresh attach" `Quick interrupted_reservation;
    test_case "browser service concurrent channels exact owner cancellation and failed readiness" `Quick browser_installation]]
