open Masc
module R = Lane_addon_runtime
module B = Browser_lane
module W = Browser_addon_wire
type t = {stop:unit -> unit}
let detach t=t.stop ()
let require = function Ok value -> value | Error detail -> failwith detail
let write path data =
  let temp=path ^ ".tmp" in
  Out_channel.with_open_bin temp (fun out -> output_string out data);
  Unix.rename temp path
let rec remove path=match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | Unix.S_REG|Unix.S_LNK|Unix.S_CHR|Unix.S_BLK|Unix.S_FIFO|Unix.S_SOCK -> Unix.unlink path
let server={|import argparse,json,os,socket,sys,threading,time
p=argparse.ArgumentParser()
p.add_argument("root");p.add_argument("--socket");p.add_argument("--incarnation");p.add_argument("--max-message-bytes")
p.add_argument("--backend",required=True)
a=p.parse_args()
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.bind(a.socket);s.listen()
def control(conn):
    with conn:
        req=json.loads(conn.makefile("rb").readline())
        if req["incarnation"]!=a.incarnation: raise RuntimeError("wrong incarnation")
        op=req["operation"]
        if op=="retire":
            conn.sendall((json.dumps({"reply":"receipt"})+"\n").encode())
            return
        if op in ("download_claim","download_commit","download_release"):
            with open(os.path.join(a.root,"downloads.json")) as src: downloads=json.load(src)
            if req["id"] not in downloads: raise RuntimeError("unknown download grant")
            if op=="download_claim": result={"reply":"download","value":{"kind":"published","receipt":downloads[req["id"]]}}
            else: result={"reply":"receipt"}
            conn.sendall((json.dumps(result)+"\n").encode())
            return
        if op=="poll":
            with open(os.path.join(a.root,"polls"),"a") as out: out.write(req["client"]["clientId"]+"\n")
            conn.sendall((json.dumps({"reply":"poll","command":None,"state_id":"fixture"})+"\n").encode())
            return
        if op!="snapshot": raise RuntimeError("fixture exposes snapshot, poll, retirement and download grants only")
        with open(os.path.join(a.root,"clients.json")) as src: clients=json.load(src)
        with open(os.path.join(a.root,"owned.json")) as src: owned=json.load(src)
        result={"reply":"snapshot","snapshot":{"state":"serving","clients":clients,"owned_backends":{"automation":{"activity":"enabled","registered":owned["automation"],"session":"closed","locate":False},"stagehand":{"activity":"enabled","registered":owned["stagehand"],"session":"unknown","locate":False}}}}
        conn.sendall((json.dumps(result)+"\n").encode())
def serve():
    while True:
        conn,_=s.accept();threading.Thread(target=control,args=(conn,),daemon=True).start()
threading.Thread(target=serve,daemon=True).start()
for line in sys.stdin:
    req=json.loads(line)
    if "id" not in req: continue
    method=req["method"]
    if method=="initialize": result={"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"scripted-browser-adapter","version":"1"}}
    elif method=="tools/list":
        with open(os.path.join(a.root,"tool.json")) as src: tool=json.load(src)
        result={"tools":[{"name":"lane_observe","inputSchema":{"type":"object"}},{"name":"lane_call","inputSchema":{"type":"object"}},tool]}
    elif method=="tools/call":
        if req["params"]["name"]=="lane_call":
            if req["params"]["arguments"]["tool"]!="browser_command": raise RuntimeError("wrong exported tool")
            name=str(req["id"])
            path=os.path.join(a.root,"requests",name+".json")
            with open(path+".tmp","w") as out: json.dump(req["params"]["arguments"],out)
            os.replace(path+".tmp",path)
            answer=os.path.join(a.root,"answers",name+".json")
            while not os.path.exists(answer): time.sleep(0.001)
            with open(answer) as src: result=json.load(src)
            os.unlink(answer)
        else: result={"content":[],"structuredContent":{"rows":[],"coverage":[]}}
    else: raise RuntimeError(method)
    print(json.dumps({"jsonrpc":"2.0","id":req["id"],"result":result}),flush=True)
|}
(* The failure class and effect phase the scripted adapter reports for a
   lane answer, read from the answer as the browser host wrote it. *)
let answer_result ~lane ~tool_name ~start_time = function
  | B.Answered (`Assoc fields) ->
    (match List.assoc_opt "ok" fields, List.assoc_opt "data" fields with
     | Some (`Bool true), Some data -> Tool_result.make_ok ~tool_name ~start_time ~data ()
     | Some (`Bool false), _ ->
       let message = match List.assoc_opt "error" fields with
         | Some (`String message) -> message
         | _ -> "browser backend failed without an error message" in
       let effect_disposition = match List.assoc_opt "effectPhase" fields with
         | Some (`String "not_started") -> Tool_result.Proven_pre_effect
         | Some (`String "partial") -> Tool_result.Proven_post_effect
         | Some _ | None -> Tool_result.Effect_outcome_unknown in
       Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Workflow_rejection
         ?data:(List.assoc_opt "data" fields) ~effect_disposition message
     | _ -> Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
         "invalid browser backend response")
  | B.Answered _ ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
      "invalid browser backend response"
  | B.Lane_absent ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Dependency_unavailable
      ~effect_disposition:Tool_result.Proven_pre_effect
      (Printf.sprintf "the %s browser lane is absent" (B.Lane_name.to_wire lane))
  | B.Timed_out ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Dependency_unavailable
      "the browser lane did not answer in time; the dispatched outcome is unknown"
  | B.Rejected_before_effect reason ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Workflow_rejection
      ~effect_disposition:Tool_result.Proven_pre_effect reason
  | B.Refused reason ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Workflow_rejection reason
(* A worker states no browser identity; the host adds the one it chose. *)
let response ~route verb answer =
  let data=W.reply_to_json (W.Issue_result (Ok answer)) in
  let typed=answer_result ~lane:(B.route_lane_name route)
    ~tool_name:(B.verb_to_string verb) ~start_time:(Tool_timing.start ()) answer in
  Mcp_protocol.Mcp_types.tool_result_to_yojson {
    content=[];is_error=Some (Tool_result.is_failed typed);structured_content=Some data;
    _meta=Lane_addon_tool_result.metadata typed}
(* The PATH that finds the native launcher, the Eio test context and the
   workspace for every worker of one run. [root] is removed only once every
   worker has settled. *)
let with_env ~env ~config run =
  let root=Filename.temp_dir "browser-addon-fixture-" "" in
  let previous=Sys.getenv_opt "PATH" in
  let launcher=Filename.concat (Filename.dirname Sys.executable_name) "../bin/masc_native_addon_launcher.exe"
    |> Unix.realpath in
  let bin=Filename.concat root "bin" in Unix.mkdir bin 0o700;
  Unix.symlink launcher (Filename.concat bin "masc-native-addon-launcher");
  Unix.putenv "PATH" (bin ^ ":" ^ Option.value ~default:"" previous);
  let settled=ref false in
  Fun.protect ~finally:(fun () ->
    (match previous with None -> Unix.unsetenv "PATH" | Some value -> Unix.putenv "PATH" value);
    if !settled then remove root) (fun () ->
    Eio.Switch.run (fun sw ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio_context.with_test_env ~sw ~clock:(Eio.Stdenv.clock env)
        ~mono_clock:(Eio.Stdenv.mono_clock env) ~net:(Eio.Stdenv.net env) (fun () ->
        Eio_context.set_env env;
        R.For_testing.reset ();
        (* A served workspace has its .masc directory before any Lane Add-on
           attaches, and the Lane Add-on store creates only its own root under
           it. Tests that start from a bare temp directory get the same. *)
        Fs_compat.mkdir_p (Workspace.masc_dir config);
        run ~sw ~root ~settle:(fun () -> settled:=true))))
let dispatch ~config operation fields=R.dispatch ~caller:"browser-fixture"
  ~access:Lane_addon_sources.Operator_configuration ~config ~operation (`Assoc fields)
  |> Result.map_error R.error_to_string |> require
let phase ~config id =
  let instances=dispatch ~config R.Inspect ["instance_id",`String id]
    |> Yojson.Safe.Util.member "instances" |> Yojson.Safe.Util.to_list in
  match instances with
  | [instance] -> Yojson.Safe.Util.member "phase" instance
      |> Lane_addon_types.phase_of_json |> require
  | []|_::_::_ -> failwith "scripted browser worker inspection lost its exact instance"
let wait ~env predicate = let rec loop ()=if predicate () then () else
  (Eio.Time.sleep (Eio.Stdenv.clock env) 0.001;loop ()) in loop ()
(* One scripted worker under [root]/[name], attached with its own package.
   [backend] is the one source its package names, or none for the package
   that serves every source. Answers [stop] once its worker detached. *)
let start ~sw ~env ~config ~root ~name ~backend ~exports ~owned:(automation,stagehand) ~clients ~downloads ~received ~respond =
  let root=Filename.concat root name in Unix.mkdir root 0o700;
  let requests=Filename.concat root "requests" and answers=Filename.concat root "answers" in
  Unix.mkdir requests 0o700;Unix.mkdir answers 0o700;
  let tool=Browser_addon_tool.definition in
  write (Filename.concat root "clients.json")
    (Yojson.Safe.to_string (`List (List.map (fun client -> match W.client_to_json client with
       | `Assoc fields -> `Assoc (("interactions",`List [])::("lastActivities",`List [])::("spaceObservation",`Null)::fields)
       | value -> value) clients)));
  write (Filename.concat root "owned.json")
    (Yojson.Safe.to_string (`Assoc ["automation",`Bool automation;"stagehand",`Bool stagehand]));
  write (Filename.concat root "downloads.json")
    (Yojson.Safe.to_string (`Assoc downloads));
  write (Filename.concat root "tool.json") (Yojson.Safe.to_string (`Assoc [
    "name",`String tool.name;"inputSchema",tool.input_schema;
    "outputSchema",Option.get tool.output_schema]));
  let script=Filename.concat root "browser.py" in write script server;
  let manifest=Filename.concat root "lane.toml" in
  write manifest (Printf.sprintf {|id = "scripted-browser-%s"
revision = "fixture-1"
title = "Scripted browser adapter"
runtime = "host_process"
service = "browser"
%scommand = ["python3", %S, %S]
contributions = ["observe"]
[resources]
max_reply_bytes = 2097152
%s|} name (Printf.sprintf "browser_backend = %S\n" (B.Backend.to_wire backend)) script root
    (if exports then "[world.tools]\nexport = [\"browser_command\"]\ninvocation = \"host_context\"\nhooks = [\"validate_input\", \"validate_output\"]\n" else ""));
  let id=dispatch ~config R.Attach ["manifest_path",`String manifest;"run_id",`String ("fixture-" ^ name);
    "binding",`Assoc ["sources",`List []]] |> Yojson.Safe.Util.member "instance_id"
    |> Yojson.Safe.Util.to_string in
  let respond_file name=
    let path=Filename.concat requests name in
    let request=Yojson.Safe.from_file path in Unix.unlink path;
    let arguments=Yojson.Safe.Util.member "arguments" request in
    let route=match Yojson.Safe.Util.member "lane" arguments,Yojson.Safe.Util.member "clientId" arguments with
      | `String "live",`String raw -> B.Live_route (Some (require (B.client_id_of_string raw)))
      | `String "stagehand",`Null -> B.Stagehand_route
      | `String "automation",`Null -> B.Automation_route
      | _ -> failwith "invalid fixture browser connection" in
    let verb=require (W.verb_of_json ~route (Yojson.Safe.Util.member "command" arguments)) in
    received ~route;
    let known=match route with B.Live_route (Some id) ->
        List.exists (fun (client:B.client_info) -> client.client_id=id) clients
      | Automation_route|Stagehand_route -> true | Live_route None -> false in
    let result=if known then response ~route verb (respond ~route verb)
      else
        let typed=Tool_result.make_err ~tool_name:"browser_command" ~start_time:(Tool_timing.start ())
          ~class_:Tool_result.Dependency_unavailable ~effect_disposition:Tool_result.Proven_pre_effect
          "selected fixture browser is disconnected" in
        Mcp_protocol.Mcp_types.tool_result_to_yojson {content=[];is_error=Some true;
          structured_content=Some (W.reply_to_json (W.Service_refusal {
            message="selected fixture browser is disconnected";disposition=W.Not_started}));
          _meta=Lane_addon_tool_result.metadata typed} in
    write (Filename.concat answers name) (Yojson.Safe.to_string result) in
  let running=ref true and settled=ref false in
  Eio.Switch.check sw;
  Eio.Fiber.fork ~sw (fun () ->
    while !running do
      Array.iter (fun name -> if Filename.extension name=".json" then respond_file name) (Sys.readdir requests);
      Eio.Time.sleep (Eio.Stdenv.clock env) 0.001
    done);
  let stop ()=if not !settled then Eio.Cancel.protect (fun () ->
    ignore (dispatch ~config R.Detach ["instance_id",`String id]);
    (* Detach already awaits settlement. Never-created workers may leave no
       retained record, so another Inspect cannot confirm this cleanup. *)
    running:=false;settled:=true) in
  id,stop
let serving ~config id = match phase ~config id with
  | Lane_addon_types.Failed detail -> failwith ("scripted browser worker failed before readiness: " ^ detail)
  | Detaching | Detached -> failwith "scripted browser worker stopped before readiness"
  | Attached | Observing ->
    List.exists (fun (service:R.browser_service) -> service.instance_id=id)
      (R.browser_services ~config ~access:Lane_addon_sources.Operator_configuration)
type worker = { serves : B.Backend.t; clients : B.client_info list; exports : bool }
type attached = { serves : B.Backend.t; instance_id : string; polled : unit -> string list }
(* Starts one scripted worker per entry, each of its own one-source package,
   and runs [run] once every one serves. Every worker that attached is
   detached, each on its own, and the root is removed only when all of them
   settled. *)
let run_workers ~env ~config ~downloads ~received ~respond workers run =
  with_env ~env ~config (fun ~sw ~root ~settle ->
    let started=ref [] in
    let stop ()=
      let failures=List.filter_map (fun (_,stop) -> match stop () with
        | () -> None
        | exception exn -> Some exn) (List.rev !started) in
      match failures with [] -> settle () | first :: _ -> raise first in
    Fun.protect ~finally:stop (fun () ->
      List.iteri (fun index (worker:worker) ->
        let name=Printf.sprintf "worker-%d" index in
        let id,stop=start ~sw ~env ~config ~root ~name ~backend:worker.serves ~exports:worker.exports
          ~owned:(worker.serves=B.Backend.Automation,worker.serves=B.Backend.Stagehand)
          ~clients:worker.clients ~downloads
          ~received:(received ~serves:worker.serves) ~respond:(respond ~serves:worker.serves) in
        started:=((worker.serves,id,name),stop) :: !started) workers;
      let attached=List.rev_map (fun ((serves,instance_id,name),_) ->
        let polls=Filename.concat (Filename.concat root name) "polls" in
        {serves;instance_id;polled=(fun () -> if Sys.file_exists polls
          then List.filter (fun line -> line<>"") (String.split_on_char '\n' (In_channel.with_open_bin polls In_channel.input_all))
          else [])}) !started in
      List.iter (fun (worker:attached) -> wait ~env (fun () -> serving ~config worker.instance_id)) attached;
      run ~stop attached))
(* The owned automation and Stagehand sources, and the external hosts that
   list [clients], each in its own worker answered by [respond]. *)
let with_worker ?(clients=[]) ?(downloads=[]) ~env ~config ~respond run =
  run_workers ~env ~config ~downloads ~received:(fun ~serves:_ ~route:_ -> ())
    ~respond:(fun ~serves:_ -> respond)
    [{serves=B.Backend.Automation;clients=[];exports=true};
     {serves=B.Backend.Stagehand;clients=[];exports=true};
     {serves=B.Backend.External_host;clients;exports=true}]
    (fun ~stop _ -> run {stop})
let with_workers ?(received=fun ~serves:_ ~route:_ -> ()) ~env ~config ~workers ~respond run =
  run_workers ~env ~config ~downloads:[] ~received ~respond workers (fun ~stop:_ attached -> run attached)
