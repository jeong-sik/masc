open Alcotest
module Live = Masc.Browser_addon_live_bidi
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
import base64,hashlib,http.server,json,os,pathlib,struct,sys
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
                elif method=='browsingContext.getTree':
                    if mode=='lost':os._exit(3)
                    result={'contexts':[]}
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
let reserved_port () =
  let fd=Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
  Unix.listen fd 1;
  match Unix.getsockname fd with Unix.ADDR_INET (_,port) -> fd,port
    | Unix.ADDR_UNIX _ -> fail "expected loopback reservation"
let wait_for clock predicate =
  let rec wait ()=if predicate () then () else (Eio.Time.sleep clock 0.01;wait ()) in wait ()
let gate_holder = {|import fcntl,pathlib,sys,time
gate,held,release=map(pathlib.Path,sys.argv[1:])
with gate.open('r+') as handle:
    fcntl.lockf(handle,fcntl.LOCK_EX)
    held.write_text('held')
    while not release.exists():time.sleep(.01)
|}
let scenario mode =
  let root=Unix.realpath (Filename.temp_dir ~perms:0o700 "owned-live-bidi-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let profile=Filename.concat root "profile" and allocation=Filename.concat root "allocation" in
    Unix.mkdir profile 0o700;Unix.mkdir allocation 0o700;
    let sentinel=Filename.concat profile "operator-login" in write sentinel "preserved";
    write (Filename.concat root "mode") mode;
    let binary=Filename.concat root "scripted-firefox" in write binary firefox;Unix.chmod binary 0o700;
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
            actor=Some "keeper/live-fixture";timeout_sec=B.default_timeout_sec;only_if_idle=false}) in
          if mode="gate" then Eio.Switch.run (fun sw ->
            let held=Filename.concat root "gate-held" and release=Filename.concat root "release-gate" in
            let release_gate ()=write release "release" in
            (* Release the independent process's gate even if any assertion
               fails, before protected owner cleanup joins its pending reader. *)
            Fun.protect ~finally:release_gate (fun () ->
              let blocker=Eio.Process.spawn ~sw (Eio.Stdenv.process_mgr env)
                ["python3";"-c";gate_holder;Filename.concat (Filename.concat root "child-claim") "gate";held;release] in
              let clock=Eio.Stdenv.clock env in
              wait_for clock (fun () -> Sys.file_exists held);
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
              Eio.Fiber.await_cancel ()))
          else if mode="lost" then (
            ignore (issue ());Eio.Fiber.await_cancel ())
          else (
            check bool "actual owned queue answers on its original connection" true
              (match issue () with W.Issue_result (Ok (B.Answered _)) -> true
               | Issue_result (Ok (B.Lane_absent|Timed_out|Refused _|Rejected_before_effect _))
               | Issue_result (Error _) | Snapshot_result _|Model_reply _|Download_reply _
               | Poll_result _|Receipt|Service_refusal _ -> false);
            check bool "retirement joins the original guardian and peer" true (dispatch W.Retire=W.Receipt);
            check bool "the exact original client cannot register again" true
              (match dispatch (W.Poll {client;window_sec=0.}) with W.Service_refusal _ -> true
               | Snapshot_result _|Model_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> false);
            check bool "retirement exposes no replacement UUID" true (B.connected_clients ()=[]);
            check bool "repeated retirement observes the same receipt" true (dispatch W.Retire=W.Receipt)) in
        let failure=try Live.For_testing.run ~before_command_validation:(fun () ->
          ignore (Eio.Promise.try_resolve validating ())) ~env ~owner ~directory:allocation work;None with
          | Invalid_argument detail | Sys_error detail -> Some detail in
        if mode="normal" then check (option string) "normal retirement returns" None failure
        else check bool "failed startup/lost peer does not continue serving" true (Option.is_some failure);
        check bool "owner input is fenced at termination" true (Owner.is_retired owner));
      check bool "only verified metadata admits caller work" (mode="normal" || mode="lost" || mode="gate") !entered;
      if mode="gate" then check bool "blocked validation retirement remains unknown after original stop" true
        (match !retirement with Some (W.Service_refusal {disposition=W.Outcome_unknown;_}) -> true
         | None | Some (Service_refusal {disposition=Not_started;_}|Snapshot_result _|Model_reply _
             |Download_reply _|Poll_result _|Receipt|Issue_result _) -> false);
      check string "operator profile is never cleared" "preserved" (read sentinel);
      let commands=Filename.concat root "commands" in
      if mode="occupied" then check bool "occupied port never spawns or adopts a browser" false (Sys.file_exists (Filename.concat root "spawned"))
      else (
        let calls=String.split_on_char '\n' (read commands) in
        check int "session is created once, without reattachment" 1
          (List.length (List.filter (String.equal "session.new") calls));
        if mode="wrong-pid" || mode="wrong-profile" then (
          check bool "identity mismatch executes no page command" false (List.mem "browsingContext.getTree" calls);
          check bool "unverified endpoint never receives browser.close" false (List.mem "browser.close" calls))
        else if mode="normal" then check int "original browser is closed once" 1
          (List.length (List.filter (String.equal "browser.close") calls))
        else if mode="gate" then (
          check bool "no delayed input follows gate release" false (List.mem "browsingContext.getTree" calls);
          check bool "uncertain ownership never replays browser.close" false (List.mem "browser.close" calls)));
      ok (Live.settle config ~incarnation:"0b000000-0000-4000-8000-000000000061" ~directory:allocation)))
let child mode () =
  let pid=Unix.create_process Sys.executable_name
    [|Sys.executable_name;"--case";mode;!launcher;!guardian|] Unix.stdin Unix.stdout Unix.stderr in
  check bool ("isolated owned live case " ^ mode) true (snd (Unix.waitpid [] pid)=Unix.WEXITED 0)
let () =
  if Array.length Sys.argv=5 && Sys.argv.(1)="--case" then (
    launcher:=Sys.argv.(3);guardian:=Sys.argv.(4);scenario Sys.argv.(2))
  else (
    if Array.length Sys.argv<>3 then invalid_arg "expected original native launcher and process guardian";
    launcher:=Sys.argv.(1);guardian:=Sys.argv.(2);
    run ~argv:[|Sys.argv.(0)|] "owned live BiDi identity and retirement" ["native",[
      test_case "occupied port is never adopted" `Quick (child "occupied");
      test_case "wrong process refuses before page input" `Quick (child "wrong-pid");
      test_case "wrong profile refuses before page input" `Quick (child "wrong-profile");
      test_case "original client retires once without replacement" `Quick (child "normal");
      test_case "native gate cannot hold the original process alive during retirement" `Quick (child "gate");
      test_case "unexpected peer loss fences the worker" `Quick (child "lost")]])
