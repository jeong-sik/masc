open Alcotest
module Live = Masc.Browser_addon_live_bidi
module Ego = Masc.Browser_addon_live_ego
module Owner = Masc.Browser_addon_owner
module W = Masc.Browser_addon_wire
module B = Browser_lane
let ok = function Ok value -> value | Error detail -> fail detail
let launcher=ref "" and guardian=ref ""
let write path text = Out_channel.with_open_bin path (fun channel -> output_string channel text)
let read path = In_channel.with_open_bin path In_channel.input_all
(* An actual owned child and native guardian, with a scripted BiDi endpoint.
   This exercises identity/lifetime boundaries, not a real Firefox UI. *)
let firefox = {|#!/usr/bin/env python3
import base64,hashlib,http.server,json,os,pathlib,struct,sys,time
profile=pathlib.Path(sys.argv[sys.argv.index('--profile')+1])
port=int(sys.argv[sys.argv.index('--remote-debugging-port')+1])
root=profile.parent
mode=(root/'mode').read_text()
(root/'spawned').write_text(json.dumps({'child':os.getpid(),'owner':os.getppid()}))
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def read_exact(self,count):
        data=b''
        while len(data)<count:
            part=self.rfile.read(count-len(data))
            if not part:raise EOFError()
            data+=part
        return data
    def send_frame(self,result):
        data=json.dumps(result).encode()
        head=bytes([129,len(data)]) if len(data)<126 else bytes([129,126])+struct.pack('!H',len(data))
        self.wfile.write(head+data);self.wfile.flush()
    def do_GET(self):
        key=self.headers.get('Sec-WebSocket-Key')
        if key is None:self.send_error(400);return
        self.send_response(101);self.send_header('Upgrade','websocket');self.send_header('Connection','Upgrade')
        self.send_header('Sec-WebSocket-Accept',base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode())
        self.end_headers()
        slow_count=0
        try:
            while True:
                first,second=self.read_exact(2)
                if first&15==8:return
                size=second&127
                if size==126:size=struct.unpack('!H',self.read_exact(2))[0]
                elif size==127:size=struct.unpack('!Q',self.read_exact(8))[0]
                mask=self.read_exact(4) if second&128 else None
                payload=self.read_exact(size)
                if mask:payload=bytes(value^mask[i%4] for i,value in enumerate(payload))
                request=json.loads(payload);method=request['method']
                with (root/'commands').open('a') as out:out.write(method+'\n')
                result={}
                if method=='session.new':
                    result={'sessionId':'original-session','capabilities':{'browserName':'firefox','browserVersion':'fixture',
                        'moz:profile':str(root) if mode=='wrong-profile' else str(profile),
                        'moz:processID':os.getppid() if mode=='wrong-pid' else os.getpid()}}
                elif method=='session.subscribe':
                    result={'subscription':'dialog-events'}
                elif method=='browsingContext.getTree':
                    if mode=='lost':os._exit(3)
                    if mode=='late' and not (root/'late-answered').exists():
                        time.sleep(1);(root/'late-answered').write_text('late')
                    if mode=='slow' and slow_count==0:time.sleep(1.2)
                    slow_count+=1
                    result={'contexts':[{'context':'owned'}] if mode in ['retire-release','retire-input'] else []}
                elif mode in ['retire-release','retire-input'] and method=='script.callFunction':
                    function=request['params']['functionDeclaration']
                    value=None if 'mascPointerFeedback' in function else {'url':'https://fixture.test/','title':'Fixture'}
                    result={'type':'success','result':{'type':'string','value':json.dumps(value)}}
                elif mode=='retire-input' and method=='input.performActions':
                    (root/'input-entered').write_text('entered');continue
                elif mode=='retire-release' and method=='input.performActions':
                    result={}
                elif mode=='retire-release' and method=='input.releaseActions':
                    (root/'release-entered').write_text('entered');continue
                elif mode=='retire-input' and method=='input.releaseActions':
                    (root/'release-entered').write_text('entered');result={}
                elif method not in ['browser.close','session.end']:
                    self.send_frame({'type':'error','id':request['id'],'error':'unsupported operation','message':'fixture command unavailable'});continue
                self.send_frame({'type':'success','id':request['id'],'result':result})
                if method=='browser.close':os._exit(0)
                if method=='session.end':return
        except (EOFError,BrokenPipeError,ConnectionResetError):pass
    def log_message(self,*args):pass
class Server(http.server.HTTPServer):allow_reuse_address=False
Server(('127.0.0.1',port),Handler).serve_forever()
|}
(* This SDK stand-in reports an operator-owned name and records every script;
   it never opens a task space or touches the real Ego installation. *)
let conflicting_ego = {|#!/usr/bin/env python3
import json,os,pathlib,re,socket,sys
root=pathlib.Path(__file__).resolve().parent
if sys.argv[1:]==['--version']:
    print('ego-browser 0.6.0.16\n  chromium 154.0.8037.44\n  node v24.21.0');sys.exit(0)
assert sys.argv[1:3]==['nodejs','-e'],sys.argv
path=json.loads(re.search(r'net\.createConnection\((".*?")\);',sys.argv[3]).group(1))
(root/'ego-pid').write_text(str(os.getpid()))
(root/'ego-directory').write_text(str(pathlib.Path(path).parent))
connection=socket.socket(socket.AF_UNIX);connection.connect(path)
stream=connection.makefile('rw')
for raw in stream:
    command=json.loads(raw);step=command['script'].split('\n')[0].removeprefix('// masc-ego: ')
    with (root/'ego-steps').open('a') as out:out.write(step+'\n')
    if step=='space.inspect':result={'ok':True,'value':[{'id':36,'createdBy':'user','ownership':'user'}]}
    else:result={'ok':False,'error':'unexpected '+step}
    stream.write(json.dumps({'id':command['id'],'lines':['masc-ego-result '+json.dumps(result)]})+'\n');stream.flush()
|}
let reserved_port () =
  let fd=Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
  Unix.listen fd 1;
  match Unix.getsockname fd with Unix.ADDR_INET (_,port) -> fd,port
    | Unix.ADDR_UNIX _ -> fail "expected loopback reservation"
let wait_for clock predicate =
  let rec wait ()=if predicate () then () else (Eio.Time.sleep clock 0.01;wait ()) in wait ()
let gate_holder = {|import fcntl,os,pathlib,sys,time
gate,held,release=map(pathlib.Path,sys.argv[1:4])
owner=int(sys.argv[4])
with gate.open('r+') as handle:
    fcntl.lockf(handle,fcntl.LOCK_EX)
    held.write_text('held')
    while not release.exists() and os.getppid()==owner:time.sleep(.01)
|}
let scenario mode =
  let root=Unix.realpath (Filename.temp_dir ~perms:0o700 "owned-live-bidi-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let profile=Filename.concat root "profile" and allocation=Filename.concat root "allocation" in
    Unix.mkdir profile 0o700;Unix.mkdir allocation 0o700;
    let sentinel=Filename.concat profile "operator-login" in write sentinel "preserved";
    let prefs_js=Filename.concat profile "prefs.js" and user_js=Filename.concat profile "user.js" in
    write prefs_js
      "user_pref(\"remote.prefs.recommended.applied\", true);\n\
       user_pref(\"browser.tabs.unloadOnLowMemory\", false); user_pref(\"operator.custom\", true);\n\
       user_pref(\"widget.windows.window_occlusion_tracking.enabled\", false); // operator note\n\
       user_pref(\"operator.custom2\", true);\n";
    (* Only non-occupied modes seed user.js: the occupied-port scenario asserts
       that admission never writes user.js at all, so it must start absent. *)
    if mode<>"occupied" then
      write user_js
        "user_pref(\"browser.tabs.unloadOnLowMemory\", false); user_pref(\"operator.custom\", true);\n\
         user_pref(\"widget.windows.window_occlusion_tracking.enabled\", false); // operator note\n\
         user_pref(\"operator.custom2\", true);\n";
    write (Filename.concat root "mode") mode;
    let binary=Filename.concat root "scripted-firefox" in write binary firefox;Unix.chmod binary 0o700;
    let ego=Filename.concat root "scripted-ego" in write ego conflicting_ego;Unix.chmod ego 0o700;
    let reservation,port=reserved_port () in
    if mode<>"occupied" then Unix.close reservation;
    Fun.protect ~finally:(fun () -> if mode="occupied" then Unix.close reservation) (fun () ->
      let config=ok (Live.configuration
        ~browser:{Browser_configuration.firefox=binary;profile;port}
        ~launcher:!launcher ~guardian:!guardian ~claim_directory:(Filename.concat root "child-claim")) in
      check bool "pinned configuration roundtrips" true
        (ok (Live.configuration_of_json (Live.configuration_to_json config))=config);
      let configuration=Filename.concat allocation "live-bidi.json" in
      write configuration (Yojson.Safe.to_string (Live.configuration_to_json config));Unix.chmod configuration 0o600;
      let entered=ref false and retirement=ref None in
      Eio_main.run (fun env ->
        Time_compat.set_clock (Eio.Stdenv.clock env);
        let validation,validating=Eio.Promise.create () in
        let owner=ok (Owner.create ~incarnation:"0b000000-0000-4000-8000-000000000061") in
        let dispatch command=Owner.dispatch owner {W.incarnation=Owner.incarnation owner;command} in
        let work () =
          entered:=true;
          let client=match B.connected_clients () with [client] -> client | _ -> fail "expected one original BiDi client" in
          let issue ()=dispatch (W.Issue {route=B.Live_route (Some client.client_id);verb=B.Tabs_list;
            actor=Some "keeper/live-fixture";timeout_sec=(if mode="slow" then 4. else B.default_timeout_sec);only_if_idle=false}) in
          if mode="retire-release" || mode="retire-input" then Eio.Switch.run (fun sw ->
            let clock=Eio.Stdenv.clock env in
            let verb=B.Page_interact {tab_id=1;frame_path=[];expected_url=Some "https://fixture.test/";
              action=B.Type_text {document_id="fixture";text="x"}} in
            let input=Eio.Fiber.fork_promise ~sw (fun () -> dispatch (W.Issue {
              route=B.Live_route (Some client.client_id);verb;actor=Some "keeper/live-fixture";
              timeout_sec=30.;only_if_idle=false})) in
            let held=if mode="retire-release" then "release-entered" else "input-entered" in
            Eio.Time.with_timeout_exn clock 8. (fun () ->
              wait_for clock (fun () -> Sys.file_exists (Filename.concat root held)));
            Eio.Cancel.protect (fun () ->
              let started=Eio.Time.now clock in
              let result=Eio.Time.with_timeout clock 8. (fun () -> Ok (dispatch W.Retire)) in
              (match result with
               | Ok (W.Receipt | W.Service_refusal _) -> ()
               | Ok (W.Issue_result _ | Snapshot_result _ | Model_reply _ | Extension_reply _ | Download_reply _ | Poll_result _)
               | Error `Timeout -> fail "retirement did not settle its protected release");
              check bool "retirement does not wait for the original 30-second caller" true (Eio.Time.now clock -. started < 8.);
              ignore (Eio.Promise.await input));
            Eio.Fiber.await_cancel ())
          else if mode="gate" || mode="cancel" then Eio.Switch.run (fun sw ->
            let held=Filename.concat root "gate-held" and release=Filename.concat root "release-gate" in
            let release_gate ()=write release "release" in
            (* Release the independent process's gate even if any assertion
               fails, before protected owner cleanup joins its pending reader. *)
            Fun.protect ~finally:release_gate (fun () ->
              let blocker=Eio.Process.spawn ~sw (Eio.Stdenv.process_mgr env)
                ["python3";"-c";gate_holder;Filename.concat (Filename.concat root "child-claim") "gate";held;release;string_of_int (Unix.getpid ())] in
              let clock=Eio.Stdenv.clock env in
              wait_for clock (fun () -> Sys.file_exists held);
              if mode="cancel" then (
                let input=Eio.Fiber.fork_promise ~sw (fun () ->
                  Eio.Fiber.first (fun () -> ignore (issue ()); `Answered)
                    (fun () -> Eio.Promise.await validation; `Cancelled)) in
                check bool "caller stopped while validation held the gate" true
                  (Eio.Promise.await_exn input = `Cancelled);
                release_gate ();
                ignore (Eio.Process.await blocker);
                check bool "the original connection answers the next request" true
                  (match issue () with W.Issue_result (Ok (B.Answered _)) -> true
                   | Issue_result (Ok (B.Lane_absent|Timed_out|Refused _|Rejected_before_effect _))
                   | Issue_result (Error _) | Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _
                   | Poll_result _|Receipt|Service_refusal _ -> false);
                check bool "normal retirement joins the original browser" true (dispatch W.Retire=W.Receipt))
              else (
                let input=Eio.Fiber.fork_promise ~sw issue in
                Eio.Promise.await validation;
                let retiring=Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.protect (fun () ->
                  let reply=dispatch W.Retire in retirement:=Some reply;reply)) in
                let owner_pid=Yojson.Safe.Util.(Yojson.Safe.from_string (read (Filename.concat root "spawned"))
                  |> member "owner" |> to_int) in
                wait_for clock (fun () -> not (Posix_spawn_detached.group_id_has_members owner_pid));
                check bool "gate holder is still blocking native settlement" false (Sys.file_exists release);
                check bool "process stop alone is not a cleanup receipt" true (Eio.Promise.peek retiring=None);
                release_gate ();
                ignore (Eio.Process.await blocker);
                ignore (Eio.Promise.await_exn input);
                ignore (Eio.Promise.await_exn retiring);
                Eio.Fiber.await_cancel ())))
          else if mode="lost" then (
            ignore (issue ());Eio.Fiber.await_cancel ())
          else if mode="late" then (
            (* The caller stops waiting before Firefox answers. The result
               then has nobody to go to, which says nothing about the
               connection: the next command is still served on it. *)
            check bool "a caller that stops waiting is told the command timed out" true
              (match dispatch (W.Issue {route=B.Live_route (Some client.client_id);verb=B.Tabs_list;
                  actor=Some "keeper/live-fixture";timeout_sec=0.2;only_if_idle=false}) with
               | W.Issue_result (Ok B.Timed_out) -> true
               | Issue_result (Ok (B.Answered _|Lane_absent|Refused _|Rejected_before_effect _))
               | Issue_result (Error _) | Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _
               | Poll_result _|Receipt|Service_refusal _ -> false);
            (* An ended loop also answers the queued caller, with a
               client_disconnected refusal, so only ok=true shows the
               connection kept serving. *)
            check bool "the next command is answered on the same connection after the late result" true
              (match issue () with
               | W.Issue_result (Ok (B.Answered payload)) -> Yojson.Safe.Util.member "ok" payload=`Bool true
               | Issue_result (Ok (B.Lane_absent|Timed_out|Refused _|Rejected_before_effect _))
               | Issue_result (Error _) | Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _
               | Poll_result _|Receipt|Service_refusal _ -> false);
            check bool "the first command took the fixture's late branch" true
              (Sys.file_exists (Filename.concat root "late-answered"));
            check bool "retirement after a late result joins the original guardian and peer" true
              (dispatch W.Retire=W.Receipt))
          else (
            check bool "actual owned queue answers on its original connection" true
              (match issue () with W.Issue_result (Ok (B.Answered payload)) -> Yojson.Safe.Util.member "ok" payload=`Bool true
               | Issue_result (Ok (B.Lane_absent|Timed_out|Refused _|Rejected_before_effect _))
               | Issue_result (Error _) | Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _
               | Poll_result _|Receipt|Service_refusal _ -> false);
            if mode="ego-conflict" then (
              check bool "the original connection answers again after Ego conflict" true
                (match issue () with W.Issue_result (Ok (B.Answered payload)) -> Yojson.Safe.Util.member "ok" payload=`Bool true
                 | Issue_result (Ok (B.Lane_absent|Timed_out|Refused _|Rejected_before_effect _))
                 | Issue_result (Error _) | Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _
                 | Poll_result _|Receipt|Service_refusal _ -> false);
              let published=ok (Masc.Browser_addon_observation.decode_snapshot (Owner.snapshot owner)) in
              check bool "Ego's exact unavailability is visible" true
                (match published.unavailable with
                 | [Masc.Browser_addon_observation.Ego_user_owned_name {space="masc";observed_at}] -> observed_at > 0.
                 | [] | _::_ -> false);
              let snapshot : Masc.Browser_selection.snapshot = {live_activity=B.Enabled;live_clients=published.clients;
                automation=published.automation;stagehand=published.stagehand} in
              check bool "unbound automatic selection chooses the remaining client" true
                (match Masc.Browser_selection.choose ~verb:B.Tabs_list ~bound:false ~snapshot Automatic with
                 | Ok selected -> selected.route=B.Live_route (Some client.client_id) | Error _ -> false);
              let gone=ok (B.client_id_of_string "0b000000-0000-4000-8000-000000000062") in
              check bool "an explicit disconnected identity never falls back" true
                (Masc.Browser_selection.target ~verb:B.Tabs_list ~snapshot (B.Live_route (Some gone))
                 = Error (B.Selected_client_disconnected gone));
              check bool "the SDK's temporary directory is gone before caller work" false
                (Sys.file_exists (read (Filename.concat root "ego-directory")));
              let pid=int_of_string (read (Filename.concat root "ego-pid")) in
              check bool "the SDK process was joined before caller work" true
                (match Unix.kill pid 0 with () -> false | exception Unix.Unix_error (Unix.ESRCH,_,_) -> true));
            if mode="slow" then (
              check bool "the original client remains connected after a slow answer" true
                (match B.connected_clients () with [remaining] -> remaining.client_id=client.client_id
                 | [] | _ :: _ :: _ -> false);
              check bool "the same connection answers again" true
                (match issue () with W.Issue_result (Ok (B.Answered _)) -> true
                 | Issue_result (Ok (B.Lane_absent|Timed_out|Refused _|Rejected_before_effect _))
                 | Issue_result (Error _) | Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _
                 | Poll_result _|Receipt|Service_refusal _ -> false));
            check bool "retirement joins the original guardian and peer" true (dispatch W.Retire=W.Receipt);
            check bool "the exact original client cannot register again" true
              (match dispatch (W.Poll {client;window_sec=0.}) with W.Service_refusal _ -> true
               | Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> false);
            check bool "retirement exposes no replacement UUID" true (B.connected_clients ()=[]);
            check bool "repeated retirement observes the same receipt" true (dispatch W.Retire=W.Receipt)) in
        let worker () = if mode="ego-conflict" then
            Ego.run ~env ~owner ~downloads:root {command=ego;space=Browser_configuration.Named_space "masc"} work
          else work () in
        let failure=try Live.For_testing.run ~before_command_validation:(fun () ->
          ignore (Eio.Promise.try_resolve validating ()))
          ~connection_timeout_sec:(if mode="slow" || mode="retire-release" || mode="retire-input" then 1. else B.default_timeout_sec)
          ~env ~owner ~directory:allocation worker;None with
          | Invalid_argument detail | Sys_error detail -> Some detail in
        if mode="normal" || mode="late" || mode="ego-conflict" || mode="slow" || mode="cancel" then check (option string) "normal retirement returns" None failure
        else if mode<>"retire-release" && mode<>"retire-input" then check bool "failed startup/lost peer does not continue serving" true (Option.is_some failure);
        check bool "owner input is fenced at termination" true (Owner.is_retired owner));
      check bool "only verified metadata admits caller work" (mode="normal" || mode="ego-conflict" || mode="slow" || mode="cancel" || mode="lost" || mode="gate" || mode="late" || mode="retire-release" || mode="retire-input") !entered;
      if mode="ego-conflict" then check string "the SDK only performed the read-only inspection"
        "space.inspect\n" (read (Filename.concat root "ego-steps"));
      if mode="gate" then check bool "blocked validation retirement remains unknown after original stop" true
        (match !retirement with Some (W.Service_refusal {disposition=W.Outcome_unknown;_}) -> true
         | None | Some (Service_refusal {disposition=Not_started;_}|Snapshot_result _|Model_reply _|Extension_reply _
             |Download_reply _|Poll_result _|Receipt|Issue_result _) -> false);
      check string "operator profile is never cleared" "preserved" (read sentinel);
      let commands=Filename.concat root "commands" in
      if mode="occupied" then (
        check bool "occupied port never spawns or adopts a browser" false (Sys.file_exists (Filename.concat root "spawned"));
        check bool "occupied port never writes user.js before admission" false (Sys.file_exists user_js))
      else (
        (* P2 regression: a line whose guard key is only its first statement
           keeps every other statement (and any trailing comment). Guard keys
           are still stripped from lines that are exactly one statement. *)
        check string "multi-statement operator lines are preserved verbatim, poisoned single statements stripped"
          ("user_pref(\"browser.tabs.unloadOnLowMemory\", false); user_pref(\"operator.custom\", true);\n\
            user_pref(\"widget.windows.window_occlusion_tracking.enabled\", false); // operator note\n\
            user_pref(\"operator.custom2\", true);\n") (read prefs_js);
        let pinned_user_js=read user_js in
        (* The shared line survives whole (no wholesale deletion), and each
           guard key is re-pinned as its own appended statement. *)
        check bool "user.js keeps the multi-statement operator line verbatim" true
          (List.mem
             "user_pref(\"browser.tabs.unloadOnLowMemory\", false); user_pref(\"operator.custom\", true);"
             (String.split_on_char '\n' pinned_user_js));
        check bool "user.js keeps the trailing-comment operator line verbatim" true
          (List.exists
             (fun line -> String.starts_with ~prefix:"user_pref(\"widget.windows.window_occlusion_tracking.enabled\", false);" line
                          && String.length line > 76)
             (String.split_on_char '\n' pinned_user_js));
        List.iter (fun (key,value) ->
          let expected=Printf.sprintf "user_pref(%S, %s);" key (Yojson.Safe.to_string value) in
          check bool ("user.js pins " ^ key) true
            (List.mem expected (String.split_on_char '\n' pinned_user_js)))
          Masc.Browser_gecko_profile.resource_guard_prefs;
        let calls=String.split_on_char '\n' (read commands) in
        check int "session is created once, without reattachment" 1
          (List.length (List.filter (String.equal "session.new") calls));
        if mode="wrong-pid" || mode="wrong-profile" then (
          check bool "identity mismatch executes no page command" false (List.mem "browsingContext.getTree" calls);
          check bool "unverified endpoint never receives browser.close" false (List.mem "browser.close" calls))
        else if mode="normal" || mode="late" || mode="ego-conflict" || mode="slow" || mode="cancel" then (
          check int "original browser is closed once" 1
            (List.length (List.filter (String.equal "browser.close") calls));
          if mode="late" || mode="ego-conflict" then check int "both commands reached the original Firefox" 2
            (List.length (List.filter (String.equal "browsingContext.getTree") calls)))
        else if mode="gate" then (
          check bool "no delayed input follows gate release" false (List.mem "browsingContext.getTree" calls);
          check bool "uncertain ownership never replays browser.close" false (List.mem "browser.close" calls)));
      if mode="cancel" then
        check int "only the later request reaches Firefox" 1
          (List.length (List.filter (String.equal "browsingContext.getTree") (String.split_on_char '\n' (read commands))));
      if mode="retire-input" || mode="retire-release" then
        check int "retirement sends one cleanup release on the original connection" 1
          (List.length (List.filter (String.equal "input.releaseActions") (String.split_on_char '\n' (read commands))));
      ok (Live.settle config ~incarnation:"0b000000-0000-4000-8000-000000000061" ~directory:allocation)))
let child mode () =
  let pid=Unix.create_process Sys.executable_name
    [|Sys.executable_name;"--case";mode;!launcher;!guardian|] Unix.stdin Unix.stdout Unix.stderr in
  let deadline=Monotonic_deadline.after ~seconds:20. in
  let rec wait () = match Unix.waitpid [Unix.WNOHANG] pid with
    | 0,_ when Monotonic_deadline.passed deadline ->
        Unix.kill pid Sys.sigkill; ignore (Unix.waitpid [] pid);
        failf "isolated owned live case %s exceeded its external watchdog" mode
    | 0,_ -> Unix.sleepf 0.05;wait ()
    | _,status -> status
    | exception Unix.Unix_error (Unix.EINTR,_,_) -> wait () in
  check bool ("isolated owned live case " ^ mode) true (wait ()=Unix.WEXITED 0)
let () =
  if Array.length Sys.argv=5 && Sys.argv.(1)="--case" then (
    launcher:=Unix.realpath Sys.argv.(3);guardian:=Unix.realpath Sys.argv.(4);scenario Sys.argv.(2))
  else (
    if Array.length Sys.argv<>3 then invalid_arg "expected original native launcher and process guardian";
    launcher:=Unix.realpath Sys.argv.(1);guardian:=Unix.realpath Sys.argv.(2);
    run ~argv:[|Sys.argv.(0)|] "owned live BiDi identity and retirement" ["native",[
      test_case "occupied port is never adopted" `Quick (child "occupied");
      test_case "wrong process refuses before page input" `Quick (child "wrong-pid");
      test_case "wrong profile refuses before page input" `Quick (child "wrong-profile");
      test_case "original client retires once without replacement" `Quick (child "normal");
      test_case "user-owned Ego name keeps the original BiDi peer serving" `Quick (child "ego-conflict");
      test_case "a slow request within its own window keeps the original client" `Quick (child "slow");
      test_case "a caller cancelled during validation sends no browser command" `Quick (child "cancel");
      test_case "retirement does not wait for a long unanswered input release" `Quick (child "retire-release");
      test_case "retirement during input performs one bounded release" `Quick (child "retire-input");
      test_case "native gate cannot hold the original process alive during retirement" `Quick (child "gate");
      test_case "unexpected peer loss fences the worker" `Quick (child "lost");
      test_case "a result whose caller stopped waiting keeps the connection" `Quick (child "late")]])
