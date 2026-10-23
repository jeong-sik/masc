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
import argparse,base64,fcntl,hashlib,http.server,json,os,pathlib,struct
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
let scenario ?(open_session=false) ?(refuse_delete=false) ?(wrong_profile=false) ~cancel_receipt () = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let slot=Filename.temp_dir "browser-owned-slot-" "" in
  let driver_root=Filename.temp_dir "browser-owned-driver-" "" in
  let executable=Filename.concat driver_root "geckodriver.py" in
  Out_channel.with_open_bin executable (fun out -> output_string out driver);Unix.chmod executable 0o700;
  if wrong_profile then Out_channel.with_open_bin (Filename.concat driver_root "wrong-profile") (fun _ -> ());
  let instance_id=Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
  let profile_root=Filename.temp_dir "browser-owned-profiles-" "" in
  let profiles=ok (Browser_gecko_profile.prepare_instance ~root:profile_root ~instance_id) in
  let context=ok (Socket.context ~live_bidi:None ~stagehand:None ~instance_id ~models:None
    ~automation:(Some {Masc.Browser_addon_automation.driver=executable;binary=None;profiles})) in
  let admission=lease (Native_addon_lease.prepare ~directories:[slot] ~instance_id ~cleanup_context:(Some context)) in
  let resource=ok (Socket.acquire ~admission ~directory:slot) in
  let directory=Filename.dirname (Socket.socket_path resource) in
  if refuse_delete then Out_channel.with_open_bin (Filename.concat driver_root "refuse-delete") (fun _ -> ());
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
        | Issue_result _|Snapshot_result _|Model_reply _|Download_reply _|Poll_result _|Receipt|Service_refusal _ -> false);
      if open_session then (
        let opened=Owner.dispatch owner {W.incarnation=instance_id;command=W.Issue {route=B.Automation_route;
          verb=B.Session_open {headless=Some true};actor=Some "fixture";timeout_sec=2.;only_if_idle=false}} in
        let answered_ok=match opened with
          | W.Issue_result (Ok (B.Answered (`Assoc fields))) -> List.assoc_opt "ok" fields=Some (`Bool true)
          | W.Issue_result _|Snapshot_result _|Model_reply _|Download_reply _|Poll_result _|Receipt|Service_refusal _ -> false in
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
           |Model_reply _|Download_reply _|Poll_result _|Receipt -> false)
      else check bool "private retirement joins backend cleanup" true (retired=W.Receipt) in
    if not cancel_receipt then Masc.Browser_addon_automation.run ~env ~owner ~directory work
    else (
      let committing,begin_commit=Eio.Promise.create () and proceed,finish_commit=Eio.Promise.create () in
      let context,publish_context=Eio.Promise.create () in
      let worker=Eio.Fiber.fork_promise ~sw (fun () ->
        try Eio.Cancel.sub (fun cancellation ->
          Eio.Promise.resolve publish_context cancellation;
          Masc.Browser_addon_automation.For_testing.run ~env ~owner ~directory work
            ~commit_receipt:(fun ~path ~contents ->
              Eio.Promise.resolve begin_commit ();
              Eio.Promise.await proceed;
              Eio_unix.run_in_systhread (fun () -> Fs_compat.save_file_atomic_strict path contents))) with
        | Eio.Cancel.Cancelled _ -> ()) in
      let cancellation=Eio.Promise.await context in
      Eio.Promise.await committing;
      Eio.Cancel.cancel cancellation Exit;
      Eio.Promise.resolve finish_commit ();
      Eio.Promise.await_exn worker));
  check bool "only confirmed cleanup writes a receipt" (not refuse_delete)
    (Sys.file_exists (Filename.concat directory "automation-closed.json"));
  if not refuse_delete then
    check bool "an ended session's profile is removed once its browser lets it go" true
      (List.for_all (fun profile -> not (Sys.file_exists profile)) (seen_profiles driver_root));
  lease (Native_addon_lease.retire admission);
  if refuse_delete then (
    check string "release hook never retries the original failed close" "DELETE\n"
      (In_channel.with_open_bin (Filename.concat driver_root "delete-calls") In_channel.input_all);
    check bool "unconfirmed cleanup cannot release the original allocation" true
      (Result.is_error (Socket.cleanup ~admission ~directory:slot));
    (* The actual backend scope has joined its original driver here. Remove
       this isolated fixture allocation without certifying product cleanup. *)
    Fs_compat.remove_tree directory)
  else (
    (match ok (Socket.cleanup ~admission ~directory:slot) with
     | Socket.Allocation_released -> ()
     | Allocation_retained -> Alcotest.fail "the allocation was retained, not released");
    check bool "original allocation released" false (Sys.file_exists directory));
  List.iter Fs_compat.remove_tree [slot;driver_root;profile_root])
let cancellation_child () =
  let pid=Unix.create_process Sys.executable_name [|Sys.executable_name;"--cancel-receipt"|] Unix.stdin Unix.stdout Unix.stderr in
  check bool "receipt cancellation joins cleanup" true (snd (Unix.waitpid [] pid)=Unix.WEXITED 0)
let open_bidi_child () =
  let pid=Unix.create_process Sys.executable_name [|Sys.executable_name;"--open-bidi"|] Unix.stdin Unix.stdout Unix.stderr in
  check bool "open BiDi reader settles before original switch join" true (snd (Unix.waitpid [] pid)=Unix.WEXITED 0)
let wrong_profile_child () =
  let pid=Unix.create_process Sys.executable_name [|Sys.executable_name;"--wrong-profile"|] Unix.stdin Unix.stdout Unix.stderr in
  check bool "a browser on another profile is refused and its session profile removed" true
    (snd (Unix.waitpid [] pid)=Unix.WEXITED 0)
let refused_close_child () =
  let pid=Unix.create_process Sys.executable_name [|Sys.executable_name;"--refused-close"|] Unix.stdin Unix.stdout Unix.stderr in
  check bool "rejected DELETE settles the original reader without a clean receipt" true
    (snd (Unix.waitpid [] pid)=Unix.WEXITED 0)
let () =
  if Array.to_list Sys.argv=[Sys.executable_name;"--cancel-receipt"] then
    run ~argv:[|Sys.executable_name|] "browser receipt cancellation" ["backend",[
      test_case "cancellation during receipt commit" `Quick (fun () -> scenario ~cancel_receipt:true ())]]
  else if Array.to_list Sys.argv=[Sys.executable_name;"--open-bidi"] then
    run ~argv:[|Sys.executable_name|] "browser open BiDi retirement" ["backend",[
      test_case "retire closes a real scripted BiDi reader" `Quick (scenario ~open_session:true ~cancel_receipt:false)]]
  else if Array.to_list Sys.argv=[Sys.executable_name;"--wrong-profile"] then
    run ~argv:[|Sys.executable_name|] "browser session on another profile" ["backend",[
      test_case "a session reporting another moz:profile is refused" `Quick
        (scenario ~open_session:true ~wrong_profile:true ~cancel_receipt:false)]]
  else if Array.to_list Sys.argv=[Sys.executable_name;"--refused-close"] then
    run ~argv:[|Sys.executable_name|] "browser refused DELETE retirement" ["backend",[
      test_case "rejected DELETE leaves cleanup unconfirmed after reader cancellation" `Quick
        (scenario ~open_session:true ~refuse_delete:true ~cancel_receipt:false)]]
  else run "browser owned driver lifecycle" ["backend",[
    test_case "owned driver readiness, command and retirement" `Quick (fun () -> scenario ~cancel_receipt:false ());
    test_case "receipt cancellation joins cleanup" `Quick cancellation_child;
    test_case "open BiDi reader joins retirement" `Quick open_bidi_child;
    test_case "a session on another profile is refused" `Quick wrong_profile_child;
    test_case "rejected DELETE still joins the original BiDi reader" `Quick refused_close_child]]
