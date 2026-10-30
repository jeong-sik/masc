open Alcotest
open Masc
module Owner = Masc.Browser_addon_owner
module Socket = Masc.Browser_addon_socket
module B = Browser_lane
module W = Masc.Browser_addon_wire
let ok = function Ok value -> value | Error detail -> fail detail
let lease result=ok (Result.map_error Native_addon_lease.error_to_string result)
(* An actual external HTTP driver process, with no personal browser/profile.
   This proves backend lifecycle wiring, not Firefox behavior. *)
let driver = {|#!/usr/bin/env python3
import argparse,base64,fcntl,hashlib,http.server,json,os,pathlib,struct,threading,time
p=argparse.ArgumentParser()
p.add_argument("--host");p.add_argument("--port",type=int)
p.add_argument("--websocket-port")
a=p.parse_args()
root=pathlib.Path(__file__).resolve().parent
held={}
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def send_json(self,value,status=200):
        body=json.dumps({"value":value}).encode()
        self.send_response(status);self.send_header("Content-Length",str(len(body)))
        self.end_headers();self.wfile.write(body)
    def read_exact(self,count):
        body=b""
        while len(body)<count:
            chunk=self.rfile.read(count-len(body))
            if not chunk:raise EOFError()
            body+=chunk
        return body
    def bidi(self):
        key=self.headers["Sec-WebSocket-Key"]
        accept=base64.b64encode(hashlib.sha1((key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101);self.send_header("Upgrade","websocket")
        self.send_header("Connection","Upgrade");self.send_header("Sec-WebSocket-Accept",accept)
        self.end_headers()
        try:
            while True:
                first,second=self.read_exact(2)
                if first&15==8:return
                count=second&127
                if count==126:count=struct.unpack("!H",self.read_exact(2))[0]
                elif count==127:count=struct.unpack("!Q",self.read_exact(8))[0]
                mask=self.read_exact(4) if second&128 else None
                payload=self.read_exact(count)
                if mask:payload=bytes(value^mask[index%4] for index,value in enumerate(payload))
                request=json.loads(payload)
                method=request["method"]
                assert method in ["session.subscribe","browsingContext.getTree","browser.setDownloadBehavior"],method
                result={"contexts":[]} if method=="browsingContext.getTree" else {}
                response=json.dumps({"type":"success","id":request["id"],"result":result}).encode()
                self.wfile.write(bytes([129,len(response)])+response);self.wfile.flush()
        except (EOFError,ConnectionError):pass
    def do_GET(self):
        if self.path=="/session/owned":return self.bidi()
        assert self.path=="/status",self.path
        # A driver that exits on its own soon after it became ready.
        if (root/"exit-after-ready").exists() and not held.get("exiting"):
            held["exiting"]=True;threading.Timer(0.5,lambda:os._exit(0)).start()
        self.send_json({"ready":True})
    def do_POST(self):
        assert self.path=="/session",self.path
        caps=json.loads(self.rfile.read(int(self.headers.get("Content-Length",0))))
        args=caps["capabilities"]["alwaysMatch"]["moz:firefoxOptions"]["args"]
        profile=args[args.index("-profile")+1]
        assert os.path.isdir(profile),profile
        # Hold the profile lock while the session runs, as Firefox does.
        lock=os.open(os.path.join(profile,".parentlock"),os.O_RDWR|os.O_CREAT,0o600)
        fcntl.lockf(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        held["lock"]=lock
        with (root/"profiles-seen").open("a") as output:output.write(profile+"\n")
        # A creation answer without a session id, after the browser started.
        if (root/"no-session-id").exists():return self.send_json({"capabilities":{}})
        # A creation that answers after the command's deadline.
        if (root/"slow-session").exists():time.sleep(30)
        reported="/elsewhere/profile" if (root/"wrong-profile").exists() else profile
        self.send_json({"sessionId":"owned","capabilities":{"moz:profile":reported,
            "webSocketUrl":f"ws://{a.host}:{a.port}/session/owned"}})
    def do_DELETE(self):
        assert self.path=="/session/owned",self.path
        if (root/"refuse-delete").exists():
            with (root/"delete-calls").open("a") as output:output.write("DELETE\n")
            return self.send_json({"error":"unknown error","message":"original DELETE refused"},status=500)
        if "lock" in held:os.close(held.pop("lock"))
        self.send_json(None)
http.server.ThreadingHTTPServer((a.host,a.port),Handler).serve_forever()
|}
let seen_profiles driver_root =
  match In_channel.with_open_bin (Filename.concat driver_root "profiles-seen") In_channel.input_all with
  | text -> String.split_on_char '\n' text |> List.filter (fun line -> line<>"")
  | exception Sys_error _ -> []
(* One instance allocation around the scripted driver. Each marker is a file
   the driver reads when it answers. *)
type instance = { slot : string; driver_root : string; profile_root : string; profiles : string;
  instance_id : string; admission : Native_addon_lease.t; directory : string }
let instance ~markers =
  let slot=Filename.temp_dir "browser-owned-slot-" "" in
  let driver_root=Filename.temp_dir "browser-owned-driver-" "" in
  let executable=Filename.concat driver_root "geckodriver.py" in
  Out_channel.with_open_bin executable (fun out -> output_string out driver);Unix.chmod executable 0o700;
  List.iter (fun marker -> Out_channel.with_open_bin (Filename.concat driver_root marker) (fun _ -> ())) markers;
  let instance_id=Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
  let profile_root=Filename.temp_dir "browser-owned-profiles-" "" in
  let profiles=ok (Browser_gecko_profile.prepare_instance ~root:profile_root ~instance_id) in
  let context=ok (Socket.context ~instance_id ~models:None
    ~source:(Socket.Automation {Masc.Browser_addon_automation.driver=executable;binary=None;profiles})) in
  let admission=lease (Native_addon_lease.prepare ~directories:[slot] ~instance_id ~cleanup_context:(Some context)) in
  let resource=ok (Socket.acquire ~admission ~directory:slot) in
  {slot;driver_root;profile_root;profiles;instance_id;admission;directory=Filename.dirname (Socket.socket_path resource)}
let scenario ?(open_session=false) ?(refuse_delete=false) ?(wrong_profile=false) () = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let {slot;driver_root;profile_root;profiles;instance_id;admission;directory}=instance
    ~markers:((if wrong_profile then ["wrong-profile"] else []) @ (if refuse_delete then ["refuse-delete"] else [])) in
  Eio.Switch.run (fun sw ->
    let owner=ok (Owner.create ~incarnation:instance_id) in
    let work () =
      let snapshot=Owner.snapshot owner in
      let owned=Yojson.Safe.Util.member "owned_backends" snapshot in
      let automation,_=ok (Masc.Browser_addon_inventory.owned_of_json owned) in
      check bool "ready driver is registered" true automation.registered;
      check bool "driver readiness does not invent an open browser" true (automation.session=B.Browser_closed);
      let snapshot={Browser_selection.live_activity=B.Enabled;live_clients=[];automation;
        stagehand={activity=B.Disabled;registered=false;session=B.Browser_closed;locate=false}} in
      let selected=Browser_selection.choose ~verb:(B.Session_open {headless=Some true}) ~bound:false
        ~snapshot Browser_selection.Automatic |> Result.map_error Browser_selection.error_message |> ok in
      check bool "automatic work chooses the registered backend" true (selected.route=B.Automation_route);
      let reply=Owner.dispatch owner {W.incarnation=instance_id;command=W.Issue {route=B.Automation_route;
        verb=B.Session_status;actor=Some "fixture";timeout_sec=2.;only_if_idle=false}} in
      check bool "command reaches owned driver client" true (match reply with
        | W.Issue_result (Ok (B.Answered (`Assoc fields))) -> List.assoc_opt "ok" fields=Some (`Bool true)
        | Issue_result _|Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|Service_refusal _ -> false);
      if open_session then (
        let opened=Owner.dispatch owner {W.incarnation=instance_id;command=W.Issue {route=B.Automation_route;
          verb=B.Session_open {headless=Some true};actor=Some "fixture";timeout_sec=2.;only_if_idle=false}} in
        let answered_ok=match opened with
          | W.Issue_result (Ok (B.Answered (`Assoc fields))) -> List.assoc_opt "ok" fields=Some (`Bool true)
          | W.Issue_result _|Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|Service_refusal _ -> false in
        if wrong_profile then
          check bool "a browser that reports another profile is refused" false answered_ok
        else (
          check bool "actual scripted BiDi reader stays open until retirement" true answered_ok;
          match seen_profiles driver_root with
          | [profile] ->
            check bool "the session runs on a masc profile in this instance" true
              (Filename.dirname profile=profiles && Sys.file_exists profile)
          | [] | _ :: _ :: _ -> Alcotest.fail "the driver did not receive exactly one session profile"));
      let retired=Owner.dispatch owner {W.incarnation=instance_id;command=W.Retire} in
      if refuse_delete then
        check bool "rejected DELETE settles retirement as unknown" true
          (match retired with W.Service_refusal {disposition=W.Outcome_unknown;_} -> true
           | Service_refusal {disposition=Not_started;_}|Issue_result _|Snapshot_result _
           |Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt -> false)
      else check bool "private retirement joins backend cleanup" true (retired=W.Receipt) in
    Masc.Browser_addon_automation.run ~env ~owner ~directory work);
  if not refuse_delete then
    check bool "an ended session's profile is removed once its browser lets it go" true
      (List.for_all (fun profile -> not (Sys.file_exists profile)) (seen_profiles driver_root));
  lease (Native_addon_lease.retire admission);
  if refuse_delete then (
    check string "release hook never retries the original failed close" "DELETE\n"
      (In_channel.with_open_bin (Filename.concat driver_root "delete-calls") In_channel.input_all);
    (* The backend scope has joined its driver, so nothing it started holds
       the allocation. The session's profile is left for the host's pass. *)
    (match ok (Socket.cleanup ~admission ~directory:slot ~kept_root:(slot ^ "-kept")) with
     | Socket.Cleanup_released -> ()
     | Cleanup_kept _ -> Alcotest.fail "the allocation moved files the test never left"
     | Cleanup_retained -> Alcotest.fail "the allocation was retained, not released");
    check bool "a session whose DELETE was refused keeps its profile for the host" true
      (List.for_all Sys.file_exists (seen_profiles driver_root) && seen_profiles driver_root <> []))
  else (
    (match ok (Socket.cleanup ~admission ~directory:slot ~kept_root:(slot ^ "-kept")) with
     | Socket.Cleanup_released -> ()
     | Cleanup_kept _ -> Alcotest.fail "the allocation moved files the test never left"
     | Cleanup_retained -> Alcotest.fail "the allocation was retained, not released");
    check bool "original allocation released" false (Sys.file_exists directory));
  List.iter Fs_compat.remove_tree [slot;driver_root;profile_root])
(* The worker of #45187 kept serving after its creation answer carried no
   session id. A worker that still serves returns from [work] after this many
   seconds, which fails the case instead of hanging it. *)
let still_serving_seconds = 10.
(* The command deadline a slow creation answer misses; the fake driver takes
   the profile lock at once and answers 30 s later. *)
let creation_deadline_seconds = 3.
let open_session ~instance_id ~timeout_sec = {W.incarnation=instance_id;command=W.Issue {route=B.Automation_route;
  verb=B.Session_open {headless=Some true};actor=Some "fixture";timeout_sec;only_if_idle=false}}
let with_instance ~marker body = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let {slot;driver_root;profile_root;profiles=_;instance_id;admission;directory}=instance ~markers:[marker] in
  let owner=ok (Owner.create ~incarnation:instance_id) in
  Fun.protect ~finally:(fun () -> List.iter Fs_compat.remove_tree [slot;driver_root;profile_root]) (fun () ->
    body ~env ~owner ~instance_id ~directory ~driver_root;
    check bool "the worker retired admission" true (Owner.is_retired owner);
    lease (Native_addon_lease.retire admission);
    (match ok (Socket.cleanup ~admission ~directory:slot ~kept_root:(slot ^ "-kept")) with
     | Socket.Cleanup_released -> ()
     | Cleanup_kept _ -> fail "the allocation moved files the test never left"
     | Cleanup_retained -> fail "the allocation was retained, not released");
    (* The host pass removes a profile the ended worker left. *)
    let left=seen_profiles driver_root in
    let outcomes=Masc.Browser_gecko_sweep.(pass (create ~termination_grace_seconds)
      (plan ~root:profile_root ~sweepable:(fun _ -> true))) in
    List.iter (fun profile ->
      check bool "the host pass removes the profile the ended worker left" true
        (List.exists (function Masc.Browser_gecko_sweep.Removed path -> String.equal path profile
           | Terminated _ | Killed _ | Kept _ -> false) outcomes && not (Sys.file_exists profile))) left))
let ends_on_its_own ~env ~owner ~directory work =
  match Masc.Browser_addon_automation.run ~env ~owner ~directory work with
  | () -> fail "the worker kept serving after it lost its session authority"
  | exception Sys_error _ -> ()
let left_by_the_browser driver_root = match seen_profiles driver_root with
  | [profile] -> check bool "the browser still held the profile, so the worker left it" true (Sys.file_exists profile)
  | [] | _ :: _ :: _ -> fail "the driver did not receive exactly one session profile"
let lost_authority ~marker () = with_instance ~marker (fun ~env ~owner ~instance_id ~directory ~driver_root ->
  ends_on_its_own ~env ~owner ~directory (fun () ->
    ignore (Owner.dispatch owner (open_session ~instance_id ~timeout_sec:creation_deadline_seconds));
    Eio.Time.sleep (Eio.Stdenv.clock env) still_serving_seconds);
  left_by_the_browser driver_root)
(* Retirement cancels a creation in flight. That loss belongs to the worker's
   own stop: [run] returns, and Retire reports the cleanup as unconfirmed. *)
let retire_during_creation () = with_instance ~marker:"slow-session"
  (fun ~env ~owner ~instance_id ~directory ~driver_root ->
    let retired=ref None in
    let clock=Eio.Stdenv.clock env in
    let work () = Eio.Fiber.both
      (fun () -> ignore (Owner.dispatch owner (open_session ~instance_id ~timeout_sec:still_serving_seconds)))
      (fun () ->
        Eio.Time.with_timeout_exn clock still_serving_seconds (fun () ->
          while seen_profiles driver_root = [] do Eio.Time.sleep clock 0.01 done);
        retired:=Some (Owner.dispatch owner {W.incarnation=instance_id;command=W.Retire})) in
    (match Masc.Browser_addon_automation.run ~env ~owner ~directory work with
     | () -> ()
     | exception Sys_error detail -> fail ("the worker raised during its own stop: " ^ detail));
    check bool "Retire reports the interrupted creation as unconfirmed cleanup" true
      (match !retired with
       | Some (W.Service_refusal {disposition=W.Outcome_unknown;_}) -> true
       | Some (W.Service_refusal {disposition=W.Not_started;_}|W.Issue_result _|W.Snapshot_result _
              |W.Model_reply _|W.Extension_reply _|W.Download_reply _|W.Poll_result _|W.Receipt) | None -> false);
    left_by_the_browser driver_root)
(* A driver that exits while the worker serves leaves no session it can address. *)
let driver_exit () = with_instance ~marker:"exit-after-ready"
  (fun ~env ~owner ~instance_id:_ ~directory ~driver_root:_ ->
    ends_on_its_own ~env ~owner ~directory (fun () -> Eio.Time.sleep (Eio.Stdenv.clock env) still_serving_seconds))
let lost_authority_child flag () =
  let pid=Unix.create_process Sys.executable_name [|Sys.executable_name;flag|] Unix.stdin Unix.stdout Unix.stderr in
  check bool "the case passes in its own process" true (snd (Unix.waitpid [] pid)=Unix.WEXITED 0)
let open_bidi_child () =
  let pid=Unix.create_process Sys.executable_name [|Sys.executable_name;"--open-bidi"|] Unix.stdin Unix.stdout Unix.stderr in
  check bool "open BiDi reader settles before original switch join" true (snd (Unix.waitpid [] pid)=Unix.WEXITED 0)
let wrong_profile_child () =
  let pid=Unix.create_process Sys.executable_name [|Sys.executable_name;"--wrong-profile"|] Unix.stdin Unix.stdout Unix.stderr in
  check bool "a browser on another profile is refused and its session profile removed" true
    (snd (Unix.waitpid [] pid)=Unix.WEXITED 0)
let refused_close_child () =
  let pid=Unix.create_process Sys.executable_name [|Sys.executable_name;"--refused-close"|] Unix.stdin Unix.stdout Unix.stderr in
  check bool "rejected DELETE settles the original reader" true
    (snd (Unix.waitpid [] pid)=Unix.WEXITED 0)
let () =
  if Array.to_list Sys.argv=[Sys.executable_name;"--open-bidi"] then
    run ~argv:[|Sys.executable_name|] "browser open BiDi retirement" ["backend",[
      test_case "retire closes a real scripted BiDi reader" `Quick (scenario ~open_session:true)]]
  else if Array.to_list Sys.argv=[Sys.executable_name;"--wrong-profile"] then
    run ~argv:[|Sys.executable_name|] "browser session on another profile" ["backend",[
      test_case "a session reporting another moz:profile is refused" `Quick
        (scenario ~open_session:true ~wrong_profile:true)]]
  else if Array.to_list Sys.argv=[Sys.executable_name;"--no-session-id"] then
    run ~argv:[|Sys.executable_name|] "browser lost session authority" ["backend",[
      test_case "a creation answer without a session id ends the worker" `Quick
        (lost_authority ~marker:"no-session-id")]]
  else if Array.to_list Sys.argv=[Sys.executable_name;"--slow-session"] then
    run ~argv:[|Sys.executable_name|] "browser interrupted session creation" ["backend",[
      test_case "a creation the command deadline interrupts ends the worker" `Quick
        (lost_authority ~marker:"slow-session")]]
  else if Array.to_list Sys.argv=[Sys.executable_name;"--retire-during-creation"] then
    run ~argv:[|Sys.executable_name|] "browser retirement during session creation" ["backend",[
      test_case "retirement during a creation stops the worker without raising" `Quick retire_during_creation]]
  else if Array.to_list Sys.argv=[Sys.executable_name;"--driver-exit"] then
    run ~argv:[|Sys.executable_name|] "browser driver exit while serving" ["backend",[
      test_case "a driver that exits while serving ends the worker" `Quick driver_exit]]
  else if Array.to_list Sys.argv=[Sys.executable_name;"--refused-close"] then
    run ~argv:[|Sys.executable_name|] "browser refused DELETE retirement" ["backend",[
      test_case "rejected DELETE leaves cleanup unconfirmed after reader cancellation" `Quick
        (scenario ~open_session:true ~refuse_delete:true)]]
  else run "browser owned driver lifecycle" ["backend",[
    test_case "owned driver readiness, command and retirement" `Quick (fun () -> scenario ());
    test_case "open BiDi reader joins retirement" `Quick open_bidi_child;
    test_case "a session on another profile is refused" `Quick wrong_profile_child;
    test_case "rejected DELETE still joins the original BiDi reader" `Quick refused_close_child;
    test_case "a creation answer without a session id ends the worker" `Quick
      (lost_authority_child "--no-session-id");
    test_case "an interrupted creation ends the worker" `Quick (lost_authority_child "--slow-session");
    test_case "retirement during a creation stops the worker without raising" `Quick
      (lost_authority_child "--retire-during-creation");
    test_case "a driver that exits while serving ends the worker" `Quick (lost_authority_child "--driver-exit")]]
