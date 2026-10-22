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
schema={"type":"object","properties":{
    "context":{"type":"object","properties":{"instance_id":{"type":"string"},"incarnation":{"type":"string"}},
        "required":["instance_id","incarnation"],"additionalProperties":False},
    "request_id":{"type":"string"},
    "action":{"type":"object","properties":{},"additionalProperties":False}},
    "required":["context","request_id","action"],"additionalProperties":False}
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
let write_native_manifest root =
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
  manifest
let native_installation_with_slot seed_slot () = with_fixture (fun clock root config ->
  let manifest = write_native_manifest root in
  let attach () = dispatch config R.Attach ["manifest_path",`String manifest;
    "run_id",`String "native-world";"binding",`Assoc ["sources",`List []]] |> text "instance_id" in
  let inspect id = dispatch config R.Inspect ["instance_id",`String id]
    |> member "instances" |> Yojson.Safe.Util.to_list |> List.hd in
  let detached id = let item = inspect id in
    text "kind" (member "phase" item)="detached" && text "runtime_presence" item="retained" in
  let ready id =
    let current = inspect id in
    match require (Lane_addon_lifecycle.state_of_json (member "lifecycle" current)) with
    | Lane_addon_lifecycle.Failed failure -> fail (Lane_addon_lifecycle.failure_detail failure.cause)
    | Detaching _ | Detached _ -> fail "native fixture retired before observation"
    | Attached | Observing -> (current |> member "observation_seq" |> Yojson.Safe.Util.to_int)>0 in
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
(* The operator takes over an instance whose cleanup was not confirmed. Only
   the operator may, only for that failure, and a refusal leaves the record as
   it was. A browser allocation whose Gecko receipt is missing stays where it
   is, and no later recovery reports it released. *)
let operator_retain () = with_fixture (fun clock root config ->
  let manifest = write_native_manifest root in
  let id = dispatch config R.Attach ["manifest_path",`String manifest;
    "run_id",`String "native-world";"binding",`Assoc ["sources",`List []]] |> text "instance_id" in
  let inspect id = dispatch config R.Inspect ["instance_id",`String id]
    |> member "instances" |> Yojson.Safe.Util.to_list |> List.hd in
  let lifecycle id = require (Lane_addon_lifecycle.state_of_json (member "lifecycle" (inspect id))) in
  wait clock (fun () -> match lifecycle id with
    | Lane_addon_lifecycle.Attached | Observing -> (inspect id |> member "observation_seq" |> Yojson.Safe.Util.to_int)>0
    | Failed failure -> fail (Lane_addon_lifecycle.failure_detail failure.cause)
    | Detaching _ | Detached _ -> fail "native fixture retired before observation");
  let captured = match inspect id with `Assoc fields -> fields | _ -> fail "captured binding is not an object" in
  ignore (dispatch config R.Detach ["instance_id",`String id]);
  wait clock (fun () -> match lifecycle id with
    | Lane_addon_lifecycle.Detached _ -> true | Attached | Observing | Failed _ | Detaching _ -> false);
  R.For_testing.reset ();
  let store = Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  (* The captured record, as instance [instance_id] admitted under its own
     installation slot, failed with [cause]. *)
  let seed ~instance_id ~authority cause =
    let state = Lane_addon_lifecycle.Failed (Lane_addon_lifecycle.failed cause) in
    let replaced = ["instance_id";"incarnation";"execution_authority";"resource";"phase";"lifecycle"] in
    require (Lane_addon_store.save_binding store ~instance_id
      (`Assoc (["instance_id",`String instance_id;"incarnation",`String instance_id;
        "execution_authority",authority;"resource",`Null;
        "phase",Lane_addon_types.phase_to_json (Lane_addon_lifecycle.project state);
        "lifecycle",Lane_addon_lifecycle.state_to_json state]
        @ List.filter (fun (name,_) -> not (List.mem name replaced)) captured))) in
  let unconfirmed = Lane_addon_lifecycle.Cleanup_unconfirmed "missing automation-closed.json" in
  let retain ?(access=Lane_addon_sources.Operator_configuration) id =
    R.dispatch ~caller:"retain-tester" ~access ~config ~operation:R.Retain (`Assoc ["instance_id",`String id]) in
  let still_failed id = match lifecycle id with
    | Lane_addon_lifecycle.Failed _ -> true | Attached | Observing | Detaching _ | Detached _ -> false in
  let release_kind id = inspect id |> member "lifecycle" |> member "release" |> text "kind" in
  let authority = List.assoc "execution_authority" captured in
  seed ~instance_id:id ~authority (Lane_addon_lifecycle.Worker_failed "start refused");
  check bool "a failure other than unconfirmed cleanup is not retained" true
    (Result.is_error (retain id) && still_failed id);
  seed ~instance_id:id ~authority unconfirmed;
  check bool "a Keeper cannot retain" true
    (Result.is_error (retain ~access:(Lane_addon_sources.Keeper "native-keeper") id) && still_failed id);
  check bool "an unauthenticated caller cannot retain" true
    (Result.is_error (retain ~access:Lane_addon_sources.Unauthenticated id) && still_failed id);
  ignore (dispatch config R.Retain ["instance_id",`String id]);
  check string "an instance with no allocation left is found released" "native_released" (release_kind id);
  check bool "a detached instance is not retained again" true (Result.is_error (retain id));
  (* A browser allocation admitted under the record's own installation slot:
     the worker never wrote its Gecko receipt and a profile was left behind. *)
  let browser_instance () =
    let instance_id = Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
    let slot = Filename.concat (Filename.concat (Lane_addon_store.root store) "native-claims")
      (Lane_addon_store.digest instance_id) in
    Unix.mkdir slot 0o700;
    let lease result = result |> Result.map_error Native_addon_lease.error_to_string |> require in
    let context = require (Browser_addon_socket.context ~instance_id ~stagehand:None ~live_bidi:None ~models:None
      ~automation:(Some {Browser_configuration.driver="/fixture/geckodriver";binary=None})) in
    let admission = lease (Native_addon_lease.prepare ~directories:[slot] ~instance_id ~cleanup_context:(Some context)) in
    let allocation = require (Browser_addon_socket.acquire ~admission ~directory:slot) in
    let profiles = Filename.concat (Filename.dirname (Browser_addon_socket.socket_path allocation)) "profiles" in
    Unix.mkdir profiles 0o700;
    let left = Filename.concat profiles "escaped-browser-profile" in write left "kept";
    lease (Native_addon_lease.retire admission);
    seed ~instance_id ~authority:(Lane_addon_lifecycle.authority_to_json
      (Lane_addon_lifecycle.Native_admission {installation_id=instance_id})) unconfirmed;
    (instance_id, admission, slot, left) in
  let cleanup_refused id = Result.is_error
    (R.dispatch ~caller:"retain-tester" ~access:Lane_addon_sources.Operator_configuration ~config
      ~operation:R.Detach (`Assoc ["instance_id",`String id])) in
  let first, _, _, left = browser_instance () in
  Fun.protect ~finally:(fun () -> remove (Filename.dirname (Filename.dirname left))) (fun () ->
    check bool "recovery cannot release an allocation without its receipt" true (cleanup_refused first && still_failed first);
    ignore (dispatch config R.Retain ["instance_id",`String first]);
    check string "the operator's retention is recorded" "native_retained" (release_kind first);
    check bool "the left profile stays in place" true (Sys.file_exists left));
  (* The acquisition was retained but the binding still says Failed, as when
     the binding write of a retain did not land: recovery reports the
     retention, never a release. *)
  let second, admission, slot, left = browser_instance () in
  Fun.protect ~finally:(fun () -> remove (Filename.dirname (Filename.dirname left))) (fun () ->
    check bool "the allocation is retained" true
      (require (Browser_addon_socket.retain ~admission ~directory:slot) = Browser_addon_socket.Allocation_retained);
    ignore (dispatch config R.Detach ["instance_id",`String second]);
    check string "recovery of a retained allocation is not a release" "native_retained" (release_kind second);
    check bool "the left profile stays in place" true (Sys.file_exists left)))
let browser_server = {|import argparse,hashlib,json,os,socket,subprocess,sys,threading
p=argparse.ArgumentParser()
p.add_argument("root");p.add_argument("mode")
p.add_argument("--socket");p.add_argument("--incarnation");p.add_argument("--max-message-bytes")
a=p.parse_args()
environment_check='''import json,os
print(json.dumps({"provider_absent":"OPENAI_API_KEY" not in os.environ,
 "unlisted_absent":"MASC_BROWSER_UNLISTED_SECRET" not in os.environ,
 "path_present":bool(os.getenv("PATH")),"locale_preserved":os.getenv("LANG")=="C",
 "backend_preserved":os.getenv("EIO_BACKEND")=="posix"}))'''
child_environment=json.loads(subprocess.check_output([sys.executable,"-c",environment_check]))
worker_environment={"provider_absent":"OPENAI_API_KEY" not in os.environ,
 "unlisted_absent":"MASC_BROWSER_UNLISTED_SECRET" not in os.environ,
 "path_present":bool(os.getenv("PATH")),"locale_preserved":os.getenv("LANG")=="C",
 "backend_preserved":os.getenv("EIO_BACKEND")=="posix"}
with open(os.path.join(a.root,"environment-"+a.incarnation),"w") as out:
    json.dump({"worker":worker_environment,"child":child_environment},out)
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.bind(a.socket);s.listen()
with open(os.path.join(a.root,"endpoint-"+a.incarnation),"w") as out: out.write(a.socket)
event=threading.Event();payload=None;running=False;clients={}
def handle(conn):
    global payload,running
    with conn:
        req=json.loads(conn.makefile("rb").readline())
        if req["incarnation"]!=a.incarnation: raise RuntimeError("wrong owner")
        op=req["operation"]
        if op=="snapshot": result={"reply":"receipt"} if a.mode=="bad_ready" or os.path.exists(os.path.join(a.root,"reject-snapshot-"+a.incarnation)) else {"reply":"snapshot","snapshot":{"command_running":running,"state":"serving","clients":list(clients.values()),"owned_backends":{"automation":{"activity":"disabled","registered":False,"session":"closed","locate":False},"stagehand":{"activity":"disabled","registered":False,"session":"unknown","locate":False}}}}
        elif op=="poll":
            client=dict(req["client"]);client["interactions"]=[];clients[client["clientId"]]=client
            result={"reply":"poll","command":None,"state_id":hashlib.sha256(json.dumps({"command_running":running}).encode()).hexdigest()}
        elif op=="disconnect":
            clients.pop(req["clientId"],None);result={"reply":"receipt"}
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
    elif method=="tools/list":
        with open(os.path.join(a.root,"browser-tool.json")) as source: tool=json.load(source)
        result={"tools":[{"name":name,"inputSchema":{"type":"object"}} for name in ["lane_observe","lane_call"]]+[tool]}
    elif method=="tools/call":
        if req["params"]["name"]=="lane_call":
            if req["params"]["arguments"]["tool"]!="browser_command": raise RuntimeError("wrong export")
            with open(os.path.join(a.root,"caller-"+a.incarnation),"w") as out: json.dump(req["params"]["arguments"]["caller"],out)
            with open(os.path.join(a.root,"arguments-"+a.incarnation),"w") as out: json.dump(req["params"]["arguments"]["arguments"],out)
            event.clear();running=True
            with open(os.path.join(a.root,"issued-"+a.incarnation),"w") as out: out.write("issued")
            with open(os.path.join(a.root,"toolcalls-"+a.incarnation),"a") as out: out.write("once\n")
            event.wait();running=False
            failed=not payload["ok"]
            value={"reply":"issue","answer":{"status":"answered","payload":payload},"browserSelection":{"lane":"live","clientId":"0c000000-0000-4000-8000-000000000001","reason":"explicit_browser"},"browserConnection":{"clientId":"0c000000-0000-4000-8000-000000000001","transport":"webdriver_bidi"}}
            if os.path.exists(os.path.join(a.root,"reject-tool-output-"+a.incarnation)): value={}
            result={"content":[],"structuredContent":value,"isError":failed}
            if failed:
                with open(os.path.join(a.root,"browser-failure-meta.json")) as source: result["_meta"]=json.load(source)
        else: result={"content":[],"structuredContent":{"rows":[],"coverage":[]}}
    else: raise RuntimeError(method)
    print(json.dumps({"jsonrpc":"2.0","id":req["id"],"result":result}),flush=True)
|}
let with_browser_environment work =
  let entries=["OPENAI_API_KEY","fake-host-provider-sentinel";
    "MASC_BROWSER_UNLISTED_SECRET","fake-unlisted-sentinel";"LANG","C";"EIO_BACKEND","posix"] in
  let previous=List.map (fun (key,_) -> key,Sys.getenv_opt key) entries in
  Fun.protect ~finally:(fun () -> List.iter (fun (key,value) ->
    match value with None -> Unix.unsetenv key | Some value -> Unix.putenv key value) previous)
    (fun () -> List.iter (fun (key,value) -> Unix.putenv key value) entries;work ())
let browser_installation () = with_browser_environment (fun () -> with_fixture (fun clock root config ->
  let script=Filename.concat root "browser.py" in write script browser_server;
  let tool=Browser_addon_tool.definition in
  write (Filename.concat root "browser-tool.json") (Yojson.Safe.to_string (`Assoc [
    "name",`String tool.name;"inputSchema",tool.input_schema;
    "outputSchema",Option.get tool.output_schema]));
  let partial=Tool_result.make_err ~tool_name:tool.name ~start_time:(Tool_timing.start ())
    ~class_:Tool_result.Workflow_rejection ~effect_disposition:Tool_result.Proven_post_effect "partial fixture" in
  write (Filename.concat root "browser-failure-meta.json")
    (Yojson.Safe.to_string (Option.get (Lane_addon_tool_result.metadata partial)));
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
hooks = ["validate_input", "validate_output"]
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
  let environment=In_channel.with_open_bin (Filename.concat root ("environment-"^id)) In_channel.input_all
    |> Yojson.Safe.from_string in
  List.iter (fun process -> List.iter (fun property ->
    check bool (process ^ " " ^ property) true
      (member property (member process environment) |> Yojson.Safe.Util.to_bool))
    ["provider_absent";"unlisted_absent";"path_present";"locale_preserved";"backend_preserved"]) ["worker";"child"];
  check bool "host retains its own provider credential" true
    (Sys.getenv_opt "OPENAI_API_KEY"=Some "fake-host-provider-sentinel");
  let host=match Browser_addon_host.connect ~config ~access:Lane_addon_sources.Unauthenticated
      ~principal:(Lane_addon_call_context.Host_actor "dashboard-tester") ~reserved:[] with
    | Ok host -> host | Error _ -> fail "shared browser host must connect" in
  check bool "anonymous caller cannot acquire host authority" true
    (Result.is_error (Browser_addon_host.connect ~config ~access:Lane_addon_sources.Unauthenticated
      ~principal:Lane_addon_call_context.Anonymous ~reserved:[]));
  check bool "public command cannot hide a reserved host name" true
    (Result.is_error (Browser_addon_host.connect ~config ~access:Lane_addon_sources.Unauthenticated
      ~principal:Lane_addon_call_context.Operator ~reserved:[Browser_addon_tool.definition.name]));
  check bool "public host uses selected input middleware" true
    (match Browser_addon_host.call host ~arguments:(`Assoc ["actor",`String "forged"]) with
     | Error (R.Host_refusal (Lane_addon_call_context.Rejected _)) -> true | _ -> false);
  check bool "rejected input never reaches worker" false
    (Sys.file_exists (Filename.concat root ("toolcalls-"^id)));
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
  let bidi_host=Browser_bidi_host_status.observe ~base_path:config.Workspace.base_path ~configuration:None in
  let inventory=Browser_addon_view.clients ~bidi_host host in
  check bool "view inventory reads worker clients rather than the core queue" true
    (Tool_result.is_success inventory &&
      (member "clients" (Tool_result.data inventory) |> Yojson.Safe.Util.to_list
        |> List.map (text "clientId"))=[Browser_lane.client_id_to_string client_id]);
  (* The TUI connection list decodes this report; without it the TUI takes the
     server for one from before the report and drops its BiDi host lines. *)
  check (list string) "view inventory answers clients, automatic choices and the BiDi host"
    ["clients";"automatic";"bidiHost"]
    (Yojson.Safe.Util.keys (Tool_result.data inventory));
  check bool "its BiDi host report is one the TUI reads" true
    (Result.is_ok (Browser_bidi_host_status.report_of_json (member "bidiHost" (Tool_result.data inventory))));
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
  let arguments=`Assoc ["lane",`String "live";"clientId",`String (Browser_lane.client_id_to_string client_id);
    "command",Browser_lane.verb_json Browser_lane.Tabs_list] in
  let public tool fields=Browser_addon_tools.handle ~config ~access
    ~principal:(Lane_addon_call_context.Host_actor "dashboard-tester") ~reserved:[]
    ~keeper_name:None ~tool ~tool_name:"public-browser-fixture" ~start_time:(Tool_timing.start ()) (`Assoc fields) in
  let route_fields=["lane",`String "live";"clientId",`String (Browser_lane.client_id_to_string client_id)] in
  Eio.Fiber.both (fun () ->
    let result=public Browser_capabilities.Tabs route_fields in
    check bool "public proxy retains partial effect error" true (Tool_result.is_failed result);
    check bool "public host retains original payload" true
      (Tool_result.data result |> member "structuredContent" |> member "answer" |> member "payload" = payload);
    check bool "public host retains effect metadata" true
      (Tool_result.metadata result=Lane_addon_tool_result.metadata partial);
    check string "public alias keeps its invocation name" "public-browser-fixture" (Tool_result.tool_name result);
    check bool "Keeper adapter receives producer's actual partial phase" true
      ((Keeper_tool_execution.of_tool_result result).failure_effect_disposition=Tool_result.Proven_post_effect))
    (fun () ->
      wait clock (fun () -> Sys.file_exists (issued id));
      check bool "native poll wakes running observation beside waiting MCP" true (poll client=Ok None);
      wait clock (fun () -> dispatch config R.Inspect ["instance_id",`String id]
        |> member "rows" |> Yojson.Safe.Util.to_list
        |> List.exists (fun row -> member "command_running" (member "fields" row)=`Bool true));
      check bool "running observation commits before MCP call settles" true
        (match call original Browser_addon_wire.Snapshot with
         | Ok (Browser_addon_wire.Snapshot_result value) -> member "command_running" value=`Bool true
         | Ok _|Error _ -> false);
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
  let unbound=Browser_addon_view.read host (`Assoc ["lane",`String "live";"tabId",`Int 7]) in
  check bool "tab read requires its original client before discovery" true
    (Tool_result.failure_class unbound=Some Tool_result.Policy_rejection);
  check string "missing tab binding issues no discovery command" "once\n"
    (In_channel.with_open_bin (Filename.concat root ("toolcalls-"^id)) In_channel.input_all);
  let unbound=public Browser_capabilities.Act ["lane",`String "live";
    "action",`String "open_tab";"url",`String "https://example.org/"] in
  check bool "public proxy refuses incomplete explicit live tab creation" true
    (Tool_result.failure_class unbound=Some Tool_result.Policy_rejection);
  check string "refused tab creation never calls the worker" "once\n"
    (In_channel.with_open_bin (Filename.concat root ("toolcalls-"^id)) In_channel.input_all);
  check bool "public command receives host-verified actor" true
    (Yojson.Safe.from_file (Filename.concat root ("caller-"^id))=
      `Assoc ["kind",`String "host_actor";"name",`String "dashboard-tester"]);
  Unix.unlink (issued id);
  Eio.Fiber.both (fun () -> check bool "browser result disposition retained" true
    (call original issue=Ok (Browser_addon_wire.Issue_result (Ok (Browser_lane.Answered payload)))))
    (fun () -> wait clock (fun () -> Sys.file_exists (issued id));
      check bool "reverse channel works beside waiting issue" true
        (call original (Browser_addon_wire.Deliver {client_id;id="fixture";payload})=Ok Browser_addon_wire.Receipt));
  Unix.unlink (issued id);
  let tab=`Assoc ["id",`Int 7;"title",`String "Fixture";"url",`String "https://example.org/";"active",`Bool true] in
  let complete payload=`Assoc ["ok",`Bool true;"data",payload] in
  let calls expected=In_channel.with_open_bin (Filename.concat root ("toolcalls-"^id)) In_channel.input_all=expected in
  Eio.Fiber.both (fun () ->
    let view=Browser_addon_view.read host (`Assoc []) in
    check bool "view reads the original active page" true (Tool_result.is_success view);
    let data=Tool_result.data view in
    check string "view retains worker-selected client" (Browser_lane.client_id_to_string client_id) (text "clientId" data);
    check string "view projection retains page text" "hello" (text "text" (member "page" data)))
    (fun () ->
      wait clock (fun () -> calls "once\nonce\n");
      check bool "view starts with tab discovery" true
        (Yojson.Safe.from_file (Filename.concat root ("arguments-"^id)) |> member "command" |> text "verb"="tabs.list");
      check bool "view tab result settled" true
        (Browser_addon_ingress.deliver ~config ~client ~id:"fixture" ~payload:(complete (`List [tab]))=Ok ());
      wait clock (fun () -> calls "once\nonce\nonce\n");
      let request=Yojson.Safe.from_file (Filename.concat root ("arguments-"^id)) in
      check string "second read pins the first connection" (Browser_lane.client_id_to_string client_id) (text "clientId" request);
      check bool "view page result settled" true
        (Browser_addon_ingress.deliver ~config ~client ~id:"fixture" ~payload:(complete (`Assoc [
          "url",`String "https://example.org/";"title",`String "Fixture";
          "text",`String "hello";"chars",`Int 5;"truncated",`Bool false]))=Ok ()));
  Unix.unlink (issued id);
  Eio.Fiber.both (fun () ->
    let result=public Browser_capabilities.Read (route_fields @ ["tabId",`Int 7]) in
    check bool "public text proxy completes through advertised command" true (Tool_result.is_success result);
    check string "public text uses worker's original connection" (Browser_lane.client_id_to_string client_id)
      (text "clientId" (Tool_result.data result));
    check string "public text retains page data" "public read" (text "text" (Tool_result.data result)))
    (fun () ->
      wait clock (fun () -> calls "once\nonce\nonce\nonce\n");
      let request=Yojson.Safe.from_file (Filename.concat root ("arguments-"^id)) in
      check string "public read dispatches one closed text command" "page.read" (text "verb" (member "command" request));
      check bool "public text result settled" true
        (Browser_addon_ingress.deliver ~config ~client ~id:"fixture"
          ~payload:(complete (`Assoc ["text",`String "public read"]))=Ok ()));
  Unix.unlink (issued id);
  write (Filename.concat root ("reject-tool-output-"^id)) "reject";
  Eio.Fiber.both (fun () ->
    check bool "selected output middleware preserves unknown effect" true
      (match Browser_addon_host.call host ~arguments with
       | Error (R.Outcome_unknown _) -> true | _ -> false))
    (fun () ->
      wait clock (fun () -> Sys.file_exists (issued id));
      check bool "malformed output does not prevent original settlement" true
        (Browser_addon_ingress.deliver ~config ~client ~id:"fixture"
          ~payload:(`Assoc ["ok",`Bool true;"data",`Assoc []])=Ok ()));
  check string "output refusal does not replay browser call" "once\nonce\nonce\nonce\nonce\n"
    (In_channel.with_open_bin (Filename.concat root ("toolcalls-"^id)) In_channel.input_all);
  ignore (dispatch config R.Detach ["instance_id",`String id]);
  wait clock (fun () -> let item=inspect id in
    text "kind" (member "phase" item)="detached" && text "runtime_presence" item="retained");
  wait clock (fun () -> not (Posix_spawn_detached.group_id_has_members pid));
  check bool "socket absent before release" false (Sys.file_exists (Filename.dirname (socket_path id)));
  check bool "detached handle refused" true (unavailable (call original Browser_addon_wire.Snapshot));
  let replacement=attach "normal" in let next=selected replacement in
  check bool "public handle never follows replacement export" true
    (match Browser_addon_host.call host ~arguments with Error (R.Unavailable _) -> true | _ -> false);
  check bool "public observation never follows replacement service" true
    (unavailable (Browser_addon_host.snapshot host));
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
    (List.exists (fun (service:R.browser_service) -> service.instance_id=refused) (services ()))))
let () =
  if Array.length Sys.argv<>2 then fail "expected native admission launcher path";
  launcher := Unix.realpath Sys.argv.(1);
  run ~argv:[|Sys.argv.(0)|] "lane_addon_native_runtime" ["installation",[
    test_case "actual installation action detach retained recovery reattach" `Quick native_installation;
    test_case "configuration resumes after interrupted slot namespace" `Quick interrupted_namespace;
    test_case "configuration resumes after interrupted slot metadata" `Quick interrupted_metadata;
    test_case "configuration retires unpublished reservation before fresh attach" `Quick interrupted_reservation;
    test_case "the operator retains an unconfirmed native instance" `Quick operator_retain;
    test_case "browser service concurrent channels exact owner cancellation and failed readiness" `Quick browser_installation]]
