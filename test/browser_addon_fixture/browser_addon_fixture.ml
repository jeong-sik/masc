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
a=p.parse_args()
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.bind(a.socket);s.listen()
def control(conn):
    with conn:
        req=json.loads(conn.makefile("rb").readline())
        if req["incarnation"]!=a.incarnation: raise RuntimeError("wrong incarnation")
        op=req["operation"]
        if op in ("download_claim","download_commit","download_release"):
            with open(os.path.join(a.root,"downloads.json")) as src: downloads=json.load(src)
            if req["id"] not in downloads: raise RuntimeError("unknown download grant")
            if op=="download_claim": result={"reply":"download","value":{"kind":"published","receipt":downloads[req["id"]]}}
            else: result={"reply":"receipt"}
            conn.sendall((json.dumps(result)+"\n").encode())
            return
        if op!="snapshot": raise RuntimeError("fixture exposes snapshot and download grants only")
        with open(os.path.join(a.root,"clients.json")) as src: clients=json.load(src)
        result={"reply":"snapshot","snapshot":{"state":"serving","clients":clients,"owned_backends":{"automation":{"activity":"disabled","registered":False,"session":"closed","locate":False},"stagehand":{"activity":"disabled","registered":False,"session":"unknown","locate":False}}}}
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
      ~effect_disposition:Tool_result.Proven_pre_effect (B.lane_absent_message lane)
  | B.Timed_out ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Dependency_unavailable
      "the browser lane did not answer in time; the dispatched outcome is unknown"
  | B.Rejected_before_effect reason ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Workflow_rejection
      ~effect_disposition:Tool_result.Proven_pre_effect reason
  | B.Refused reason ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Workflow_rejection reason
let response ~clients ~route verb answer =
  let selected={Browser_selection.route;reason=Browser_selection.Explicit_browser} in
  let connection=match route with
    | B.Live_route (Some id) ->
        let client=List.find (fun (client:B.client_info) -> client.client_id=id) clients in
        B.live_connection_fields ~client_id:id ~transport:client.transport
    | Automation_route|Stagehand_route -> ["clientId",`Null]
    | Live_route None -> failwith "fixture must receive a concrete live connection" in
  let data=match W.reply_to_json (W.Issue_result (Ok answer)) with
    | `Assoc fields -> `Assoc (fields @ ["browserSelection",Browser_selection.to_json selected;
        "browserConnection",`Assoc connection])
    | _ -> failwith "fixture expected issue receipt" in
  let typed=answer_result ~lane:(B.route_lane_name route)
    ~tool_name:(B.verb_to_string verb) ~start_time:(Tool_timing.start ()) answer in
  Mcp_protocol.Mcp_types.tool_result_to_yojson {
    content=[];is_error=Some (Tool_result.is_failed typed);structured_content=Some data;
    _meta=Lane_addon_tool_result.metadata typed}
let with_worker ?(clients=[]) ?(downloads=[]) ~env ~config ~respond run =
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
        R.For_testing.reset ();
        (* A served workspace has its .masc directory before any Lane Add-on
           attaches, and the Lane Add-on store creates only its own root under
           it. Tests that start from a bare temp directory get the same. *)
        Fs_compat.mkdir_p (Workspace.masc_dir config);
        let requests=Filename.concat root "requests" and answers=Filename.concat root "answers" in
        Unix.mkdir requests 0o700;Unix.mkdir answers 0o700;
        let tool=Browser_addon_tool.definition in
        write (Filename.concat root "clients.json")
          (Yojson.Safe.to_string (`List (List.map (fun client -> match W.client_to_json client with
             | `Assoc fields -> `Assoc (("interactions",`List [])::fields)
             | value -> value) clients)));
        write (Filename.concat root "downloads.json")
          (Yojson.Safe.to_string (`Assoc downloads));
        write (Filename.concat root "tool.json") (Yojson.Safe.to_string (`Assoc [
          "name",`String tool.name;"inputSchema",tool.input_schema;
          "outputSchema",Option.get tool.output_schema]));
        let script=Filename.concat root "browser.py" in write script server;
        let manifest=Filename.concat root "lane.toml" in
        write manifest (Printf.sprintf {|id = "scripted-browser"
revision = "fixture-1"
title = "Scripted browser adapter"
runtime = "host_process"
service = "browser"
command = ["python3", %S, %S]
contributions = ["observe"]
[resources]
max_reply_bytes = 2097152
[world.tools]
export = ["browser_command"]
invocation = "host_context"
hooks = ["validate_input", "validate_output"]
|} script root);
        let dispatch operation fields=R.dispatch ~caller:"browser-fixture"
          ~access:Lane_addon_sources.Operator_configuration ~config ~operation (`Assoc fields)
          |> Result.map_error R.error_to_string |> require in
        let id=dispatch R.Attach ["manifest_path",`String manifest;"run_id",`String "fixture";
          "binding",`Assoc ["sources",`List []]] |> Yojson.Safe.Util.member "instance_id"
          |> Yojson.Safe.Util.to_string in
        let inspect ()=dispatch R.Inspect ["instance_id",`String id]
          |> Yojson.Safe.Util.member "instances" |> Yojson.Safe.Util.to_list |> List.hd in
        let wait predicate = let rec loop ()=if predicate () then () else
          (Eio.Time.sleep (Eio.Stdenv.clock env) 0.001;loop ()) in loop () in
        let respond_file name=
          let path=Filename.concat requests name in
          let request=Yojson.Safe.from_file path in Unix.unlink path;
          let arguments=Yojson.Safe.Util.member "arguments" request in
          let route=match Yojson.Safe.Util.member "lane" arguments,Yojson.Safe.Util.member "clientId" arguments with
            | `String "live",`String raw -> B.Live_route (Some (require (B.client_id_of_string raw)))
            | `String "stagehand",`Null -> B.Stagehand_route
            | (`String "automation"|`Null),`Null -> B.Automation_route
            | _ -> failwith "invalid fixture browser connection" in
          let verb=require (W.verb_of_json ~route (Yojson.Safe.Util.member "command" arguments)) in
          let known=match route with B.Live_route (Some id) ->
              List.exists (fun (client:B.client_info) -> client.client_id=id) clients
            | Automation_route|Stagehand_route -> true | Live_route None -> false in
          let result=if known then response ~clients ~route verb (respond ~route verb)
            else
              let typed=Tool_result.make_err ~tool_name:"browser_command" ~start_time:(Tool_timing.start ())
                ~class_:Tool_result.Dependency_unavailable ~effect_disposition:Tool_result.Proven_pre_effect
                "selected fixture browser is disconnected" in
              Mcp_protocol.Mcp_types.tool_result_to_yojson {content=[];is_error=Some true;
                structured_content=Some (W.reply_to_json (W.Service_refusal {
                  message="selected fixture browser is disconnected";disposition=W.Not_started}));
                _meta=Lane_addon_tool_result.metadata typed} in
          write (Filename.concat answers name) (Yojson.Safe.to_string result) in
        let running=ref true in
        Eio.Switch.check sw;
        Eio.Fiber.fork ~sw (fun () ->
          while !running do
            Array.iter (fun name -> if Filename.extension name=".json" then respond_file name) (Sys.readdir requests);
            Eio.Time.sleep (Eio.Stdenv.clock env) 0.001
          done);
        let stop ()=if not !settled then Eio.Cancel.protect (fun () ->
          ignore (dispatch R.Detach ["instance_id",`String id]);
          wait (fun () -> Yojson.Safe.Util.(inspect () |> member "phase" |> member "kind")=`String "detached");
          running:=false;settled:=true) in
        Fun.protect ~finally:stop (fun () ->
          wait (fun () -> List.exists (fun (service:R.browser_service) -> service.instance_id=id)
            (R.browser_services ~config ~access:Lane_addon_sources.Operator_configuration));
          run {stop}))))
