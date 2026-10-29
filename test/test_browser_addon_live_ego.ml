open Alcotest
module Ego = Masc.Browser_addon_live_ego
module Peer = Masc.Browser_ego_peer
module Owner = Masc.Browser_addon_owner
module W = Masc.Browser_addon_wire
module Broker = Masc.Browser_addon_downloads
module B = Browser_lane
let ok = function Ok value -> value | Error detail -> fail detail
let write path text = Out_channel.with_open_bin path (fun channel -> output_string channel text)
let read path = In_channel.with_open_bin path In_channel.input_all
let lines path = if Sys.file_exists path then List.filter ((<>) "") (String.split_on_char '\n' (read path)) else []

let configuration text = Browser_configuration.parse (Otoml.Parser.from_string text)
let test_the_table_names_a_command_and_a_space () =
  (match configuration "[browser.live.ego]\ncommand = \"/opt/ego-browser\"\nspace = \"masc\"\n" with
   | Ok {Browser_configuration.live_ego = Some {command; space}; _} ->
     check string "command" "/opt/ego-browser" command; check bool "space name" true (space=Browser_configuration.Named_space "masc")
   | Ok _ -> fail "the ego table was not read"
   | Error detail -> fail detail);
  (match configuration "[browser.live]\n" with
   | Ok {Browser_configuration.live_ego = None; _} -> ()
   | Ok _ -> fail "no table configured an ego connection"
   | Error detail -> fail detail);
  List.iter (fun (name, text, refusal) ->
    check (result reject string) name (Error refusal) (Result.map ignore (configuration text)))
    [ "no command", "[browser.live.ego]\nspace = \"masc\"\n",
      "browser.live.ego.command is required when the table is configured";
      "a relative command", "[browser.live.ego]\ncommand = \"ego-browser\"\nspace = \"masc\"\n",
      "browser.live.ego.command must be a non-empty absolute path";
      "no space", "[browser.live.ego]\ncommand = \"/opt/ego-browser\"\n",
      "browser.live.ego.space is required when the table is configured";
      "a blank space", "[browser.live.ego]\ncommand = \"/opt/ego-browser\"\nspace = \" \"\n",
      "browser.live.ego.space must be a non-empty task space name or a nonnegative JavaScript-safe Space ID";
      "an unknown key", "[browser.live.ego]\ncommand = \"/opt/ego-browser\"\nspace = \"masc\"\nprofile = \"x\"\n",
      "browser.live.ego.profile is not a supported setting" ];
  check (list string) "the worker's arguments" ["--live-ego-command";"/opt/ego-browser";"--live-ego-space";"masc"]
    (Ego.arguments {command="/opt/ego-browser";space=Browser_configuration.Named_space "masc"});
  (match configuration "[browser.live.ego]\ncommand=\"/opt/ego-browser\"\nspace=32\n" with
   | Ok {Browser_configuration.live_ego=Some table;_} ->
     check bool "an integer pins an existing Space" true (table.space=Browser_configuration.Existing_space 32);
     check (list string) "ID is never passed through the name flag"
       ["--live-ego-command";"/opt/ego-browser";"--live-ego-space-id";"32"] (Ego.arguments table)
   | Ok _|Error _ -> fail "numeric Space reference rejected");
  List.iter (fun reference -> check bool "invalid numeric references cannot start the worker" true
    (Result.is_error (configuration ("[browser.live.ego]\ncommand=\"/opt/ego-browser\"\nspace=" ^ reference ^ "\n"))))
    ["-1";"9007199254740992";"32.0";"true"]

let failure_name = function
  | Peer.Exited {code; _} -> Printf.sprintf "exited %d" code
  | Peer.Signaled signal -> "signaled " ^ Process_eio.signal_name signal
  | Peer.Timed_out -> "timed out" | Peer.Output_exceeded -> "output exceeded"
  | Peer.Unobserved _ -> "unobserved" | Peer.Unstarted _ -> "unstarted"

let test_a_run_answers_both_streams_or_why_not () =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let run ?(timeout_s=5.) ?(stdin="") script =
      Ego.run_command ~env ~timeout_s ~stdin ~command:"/bin/sh" ["-c"; script] in
    (match run ~stdin:"script body" "cat; printf ' to stdout'; printf ' to stderr' >&2" with
     | Ok output ->
       check bool "stdin reached the run" true (String.starts_with ~prefix:"script body" output);
       check bool "stdout and stderr are one output" true
         (String_util.contains_substring output "to stdout" && String_util.contains_substring output "to stderr")
     | Error failure -> fail (failure_name failure));
    let failed name expected result = match result with
      | Ok _ -> failf "%s answered" name
      | Error failure -> check string name expected (failure_name failure) in
    failed "a non-zero exit" "exited 3" (run "printf partial; exit 3");
    (match run "printf partial; exit 3" with
     | Error (Peer.Exited {output; _}) -> check string "its output" "partial" output
     | Ok _ | Error _ -> fail "expected the exit");
    failed "a signal" "signaled SIGTERM" (run "kill -TERM $$");
    failed "output past the limit" "output exceeded"
      (run (Printf.sprintf "head -c %d /dev/zero" (Peer.output_limit_bytes + 1)));
    (* Its script still unwritten, because it reads none of it. A feed and
       drain paired again would end this run at its window, as timed out. *)
    failed "output past the limit from a run that does not read" "output exceeded"
      (run ~stdin:(String.make 1_000_000 'x')
         (Printf.sprintf "head -c %d /dev/zero; sleep 30" (Peer.output_limit_bytes + 1)));
    let started = Eio.Time.now clock in
    failed "a run past its window" "timed out" (run ~timeout_s:0.3 "sleep 30");
    (* The window and the stop grace (2 s), not the run's own 30 s. *)
    check bool "stopped within its window and the stop grace" true (Eio.Time.now clock -. started < 3.);
    (match Ego.run_command ~env ~timeout_s:5. ~stdin:"" ~command:"/nonexistent/ego-browser" [] with
     | Error (Peer.Unstarted _) -> ()
     | Ok _ | Error _ -> fail "a missing command started"))

let test_a_stopped_run_answers_within_the_peers_window () =
  let root = Unix.realpath (Filename.temp_dir ~perms:0o700 "owned-live-ego-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let command = Filename.concat root "ego-browser" in
    write command "#!/bin/sh\nexec sleep 30\n"; Unix.chmod command 0o700;
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      let session = Ego.session ~sw ~env ~command ~directory:root in
      let window_s = 2.5 in
      let started = Eio.Time.now clock in
      check string "the run" "timed out" (match Ego.runner session ~window_s "" with
        | Ok _ -> "answered" | Error failure -> failure_name failure);
      (* Stopping it spends the stop grace inside the window, not after it. *)
      check bool "within the window" true (Eio.Time.now clock -. started < window_s +. 0.5);
      let started = Eio.Time.now clock in
      check string "a window no longer than the stop" "unstarted" (match Ego.runner session ~window_s:1.5 "" with
        | Ok _ -> "answered" | Error failure -> failure_name failure);
      check bool "is refused before the run starts" true (Eio.Time.now clock -. started < 0.5))))

(* A stand-in for the session process: it connects to the loop's socket and
   answers each script with its pid and how many it has run, sleeps past
   the window on "sleep", answers past the output limit on "big <n>", and
   leaves on "exit". *)
let session_stand_in = {|#!/usr/bin/env python3
import json,os,re,socket,sys,time
assert sys.argv[1:3]==['nodejs','-e'],sys.argv
path=json.loads(re.search(r'net\.createConnection\((".*?")\);',sys.argv[3]).group(1))
connection=socket.socket(socket.AF_UNIX);connection.connect(path)
stream=connection.makefile('rw')
count=0
for raw in stream:
    command=json.loads(raw);script=command['script'];count+=1
    if script=='sleep':time.sleep(30)
    if script=='exit':print('leaving');sys.stdout.flush();sys.exit(4)
    lines=['x'*int(script[4:])] if script.startswith('big ') else ['%d %d'%(os.getpid(),count)]
    stream.write(json.dumps({'id':command['id'],'lines':lines})+'\n');stream.flush()
|}

(* A stand-in that writes its pid next to itself and never connects, so a
   start is still waiting for it when the start is cancelled. *)
let unconnected_stand_in = {|#!/usr/bin/env python3
import os,pathlib,time
here=pathlib.Path(__file__).resolve().parent
(here/'pid.part').write_text(str(os.getpid()));(here/'pid.part').rename(here/'pid')
time.sleep(30)
|}

let running pid = match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false

(* A start cancelled before its process connected stops that process, so
   nothing of the session keeps the connection's switch from ending, and
   the next command starts again. *)
let test_a_cancelled_start_stops_its_process () =
  let root = Unix.realpath (Filename.temp_dir ~perms:0o700 "owned-live-ego-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let command = Filename.concat root "ego-browser" in
    write command unconnected_stand_in; Unix.chmod command 0o700;
    let pid_file = Filename.concat root "pid" in
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      (* The cancel waits for the process to run, not for a fixed time,
         because an interpreter behind a version shim starts slowly. *)
      let rec until_running () =
        if not (Sys.file_exists pid_file) then (Eio.Time.sleep clock 0.05; until_running ()) in
      let ended = Eio.Time.with_timeout clock 6. (fun () ->
        Ok (Eio.Switch.run (fun sw ->
          let session = Ego.session ~sw ~env ~command ~directory:root in
          match Eio.Fiber.first
                  (fun () -> `Answered (Ego.runner session ~window_s:10. "count"))
                  (fun () -> until_running (); `Cancelled) with
          | `Answered _ -> Error "the start answered before it was cancelled"
          | `Cancelled ->
            let pid = int_of_string (String.trim (read pid_file)) in
            check bool "the process that would have connected was stopped" false (running pid);
            check bool "its socket was removed" false (Sys.file_exists (Filename.concat root "s"));
            write command session_stand_in;
            let restarted = Ego.runner session ~window_s:5. "count" in
            Ego.end_session session;
            Result.map_error failure_name restarted |> Result.map ignore))) in
      match ended with
      | Ok (Ok ()) -> ()
      | Ok (Error detail) -> failf "the next command after the cancelled start: %s" detail
      | Error `Timeout -> fail "the connection's switch did not end after its start was cancelled"))

(* A fork on a cancelled switch runs nothing, so a start there is refused
   before a process exists instead of waiting for one that never ends. *)
let test_a_start_on_a_cancelled_connection_starts_nothing () =
  let root = Unix.realpath (Filename.temp_dir ~perms:0o700 "owned-live-ego-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let command = Filename.concat root "ego-browser" in
    write command unconnected_stand_in; Unix.chmod command 0o700;
    let refused = ref false in
    Eio_main.run (fun env ->
      match Eio.Switch.run (fun sw ->
        let session = Ego.session ~sw ~env ~command ~directory:root in
        Eio.Switch.fail sw Exit;
        match Ego.runner session ~window_s:5. "count" with
        | Ok _ | Error _ -> ()
        | exception Eio.Cancel.Cancelled _ -> refused := true) with
      | () -> fail "the failed connection's switch returned"
      | exception Exit -> ());
    check bool "the start raised the connection's cancellation" true !refused;
    check bool "no process was started" false (Sys.file_exists (Filename.concat root "pid")))

let test_one_process_runs_the_connections_commands () =
  let root = Unix.realpath (Filename.temp_dir ~perms:0o700 "owned-live-ego-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let command = Filename.concat root "ego-browser" in
    write command session_stand_in; Unix.chmod command 0o700;
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      let session = Ego.session ~sw ~env ~command ~directory:root in
      let run ?(window_s=5.) script = Ego.runner session ~window_s script in
      let kind ?window_s script = match run ?window_s script with Ok _ -> "answered" | Error failure -> failure_name failure in
      let held script = match run script with
        | Ok output -> (match String.split_on_char ' ' (String.trim output) with
          | [pid; count] -> pid, int_of_string count
          | _ -> failf "%s answered %S" script output)
        | Error failure -> failf "%s: %s" script (failure_name failure) in
      let first, one = held "count" in
      let again, two = held "count" in
      check string "one process runs both scripts" first again;
      check (pair int int) "and keeps what it holds between them" (1, 2) (one, two);
      check bool "the socket is gone once the process connected" false (Sys.file_exists (Filename.concat root "s"));
      let started = Eio.Time.now clock in
      check string "a script past its window" "timed out" (kind ~window_s:3. "sleep");
      check bool "is stopped within its window" true (Eio.Time.now clock -. started < 3.5);
      let next, count = held "count" in
      check bool "the next script starts another process" true (next <> first);
      check int "which holds nothing yet" 1 count;
      check string "an answer past the output limit" "output exceeded" (kind (Printf.sprintf "big %d" (Peer.output_limit_bytes + 1)));
      (match run "exit" with
       | Error (Peer.Exited {code; output}) ->
         check int "a process that left" 4 code;
         check bool "says what it wrote" true (String_util.contains_substring output "leaving")
       | Ok _ | Error _ -> fail "expected the process to have left");
      ignore (held "count");
      let started = Eio.Time.now clock in
      Ego.end_session session;
      check bool "a process that leaves its loop is not waited out" true (Eio.Time.now clock -. started < 1.))))

(* ego-browser as the worker runs it: [--version], and [nodejs -e] with
   the session loop, which this stand-in plays: it connects to the loop's
   socket and answers each script by the step its first line names. *)
let ego = {|#!/usr/bin/env python3
import json,os,pathlib,re,socket,sys,time
root=pathlib.Path(__file__).resolve().parent
mode=(root/'mode').read_text()
if sys.argv[1:]==['--version']:
    if mode=='no-version':
        print('ego-browser: not signed in');sys.exit(3)
    print('ego-browser 0.6.0.16\n  chromium 154.0.8037.44\n  node v24.21.0');sys.exit(0)
assert sys.argv[1:3]==['nodejs','-e'],sys.argv
with open(root/'processes','a') as log:log.write(str(os.getpid())+'\n')
path=json.loads(re.search(r'net\.createConnection\((".*?")\);',sys.argv[3]).group(1))
connection=socket.socket(socket.AF_UNIX);connection.connect(path)
stream=connection.makefile('rw')
state=json.dumps({'url':'https://fixture.test/','title':'Fixture','viewport':{'width':800,'height':600}})
def run(script,answer):
    lines=script.split('\n')
    step=lines[0].removeprefix('// masc-ego: ')
    args=json.loads(json.loads(next(l for l in lines if l.startswith('const args = JSON.parse(')).removeprefix('const args = JSON.parse(').removesuffix(');')))
    with open(root/'steps','a') as log:log.write(step+'\n')
    if step=='space.inspect':
        if mode=='inspect-fails-in-use':answer(error='listing unavailable')
        elif mode=='user-owned':answer([{'id':36,'createdBy':'user','ownership':'user'}])
        else:answer([])
    elif step=='space.open':
        if mode in ['in-use','inspect-fails-in-use']:answer(error='EGO_TASK_SPACE_NAME_IN_USE: masc')
        else:answer({'spaceId':51,'name':'SDK Space','ownership':'agent'})
    elif step=='tabs.list':
        answer([{'label':'p1','targetId':'T1','openedBy':'agent','title':'Fixture','url':'https://fixture.test/','active':True,'dialog':None,'dialogUnread':None}])
    elif step=='page.capture':
        path=pathlib.Path(args['path'])
        path.write_bytes(b'\x89PNG\r\n\x1a\nfixture')
        (root/'captures').write_text(str(path.parent))
        # What a capture stopped part way leaves behind.
        (path.parent/'ego-capture-51-99.png').write_bytes(b'left')
        answer({'label':'p1','path':str(path),'before':{'answer':state},'after':{'answer':state}})
    elif step=='page.read':
        # late: done after the caller stopped waiting; retire: still running when the worker retires.
        time.sleep({'late':2.5,'retire':30}.get(mode,0))
        answer({'label':'p1','answer':{'answer':json.dumps({'url':'https://fixture.test/','title':'Fixture','text':'hi','chars':2,'truncated':False})}})
    elif step=='page.open':
        answer({'label':'p2','error':None,'tab':{'url':args['url'],'title':'Opened','active':True}})
    elif step=='page.goto':
        answer({'error':None,'tab':{'url':args['url'],'title':'Moved'}})
    elif step=='page.target':
        answer({'answer':json.dumps({'url':'https://fixture.test/','point':{'x':0.25,'y':0.5},
            'viewport':{'documentId':'d1','width':800,'height':600,'scrollX':0,'scrollY':0}})})
    elif step=='page.target_input':
        (root/'clicked').write_text(json.dumps([args['target'],args['cursor']]))
        answer({'urlBefore':'https://fixture.test/','receipt':{},'error':None,
            'tab':{'url':'https://fixture.test/','title':'Fixture'}})
    elif step=='page.native_workflow':
        if mode=='recovery':
            assert args['label']=='p1' and args['tabId']==1
            selector=args['steps'][0]['selector']
            with open(root/'recovery-inputs','a') as log:log.write(selector+'\n')
            completed=[{'index':0,'method':'click','receipt':{}}]
            if selector=='#dialog':
                dialog={'type':'alert','message':'check'}
                completed[0]['receipt']={'dialog':dialog}
                answer({'completed':completed,'effectStarted':True,'completedEffect':True,'inputReleased':False,
                    'failure':{'index':0,'method':'click','message':'answer dialog','dialog':dialog}})
            else:
                assert selector=='#continue'
                answer({'completed':completed,'effectStarted':True,'completedEffect':True,'inputReleased':True,'failure':None,
                    'urlBefore':'https://fixture.test/','url':'https://fixture.test/','title':'Fixture',
                    'snapshot':'root','truncated':False,'chars':4})
            return
        time.sleep(0.03)
        answer({'completed':[],'effectStarted':False,'completedEffect':False,'inputReleased':True,'failure':None,
            'urlBefore':'https://fixture.test/','url':'https://fixture.test/','title':'Fixture','snapshot':'root','truncated':False,'chars':4})
    elif step=='page.dialog':answer({'dialog':{'type':'alert','message':'check'}})
    elif step=='page.activate':
        answer({'spaceId':51,'label':'p1','targetId':'T1','urlBefore':'https://fixture.test/',
            'url':'https://fixture.test/','title':'Fixture','active':True,
            'window':{'windowId':7,'stateBefore':'normal','stateAfter':'normal','restored':False}})
    elif step=='page.pointer':
        page={'answer':json.dumps({'url':'https://fixture.test/','title':'Fixture','scrollX':0,'scrollY':0})}
        (root/'clicked').write_text(json.dumps([args['x'],args['y'],args['button'],args['cursor']]))
        answer({'guard':page,'receipt':page,'error':None})
    elif step=='page.downloads':
        # What the page's download wait saved: <downloads>/<id>, in folders
        # no one else may write, as ego's saveAs makes them.
        folder=pathlib.Path(args['downloads'])
        for level in (folder.parent,folder):level.mkdir(mode=0o700,exist_ok=True)
        ident='1b000000-0000-4000-8000-0000000000d1';saved=folder/ident
        saved.write_text('report');(root/'downloaded').write_text(str(saved))
        answer({'since':'2026-10-23T09:00:00.000Z','rows':[{'id':ident,'label':'p1','source':'native_download','url':'https://fixture.test/report.txt',
            'suggestedFilename':'report.txt','state':'completed','path':str(saved),'reason':None}]})
    elif step=='page.upload':
        # Ego receives the worker's copies; the peer records staged metadata.
        paths=[pathlib.Path(path) for path in args['paths']]
        (root/'uploaded').write_text(json.dumps([str(path) for path in paths]))
        answer({'error':None,'dialog':None,'tab':{'url':'https://fixture.test/','title':'Fixture'}})
    elif step=='space.status':answer({'spaceId':51,'name':'Renamed native Space','ownership':'agent'})
    elif step=='space.finish':answer({'spaceId':51,'closedSpace':True,'keptManagedLabels':[],
        'closedManagedLabels':['p1','p2'],'preservedUnmanagedCount':0})
    else:answer(error='unexpected step '+step)
for raw in stream:
    command=json.loads(raw);out=[]
    def answer(value=None,error=None):
        frame={'ok':True,'value':value} if error is None else {'ok':False,'error':error}
        out.append('masc-ego-result '+json.dumps(frame))
    run(command['script'],answer)
    stream.write(json.dumps({'id':command['id'],'lines':out})+'\n');stream.flush()
|}

let answered = function
  | W.Issue_result (Ok (B.Answered json)) -> json
  | W.Issue_result (Ok (B.Lane_absent | Timed_out | Refused _ | Rejected_before_effect _)) | W.Issue_result (Error _)
  | Snapshot_result _ | Model_reply _|Extension_reply _ | Download_reply _ | Poll_result _ | Receipt | Service_refusal _ ->
    fail "the ego connection did not answer"

let scenario mode =
  let root = Unix.realpath (Filename.temp_dir ~perms:0o700 "owned-live-ego-" "") in
  (* The connection's screenshot directory is made here, so what is left of
     it after the run can be seen. It is not under [root], whose real path
     would make the session socket's path longer than a socket's. *)
  let temporary = Filename.temp_dir ~perms:0o700 "ego-tmp-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root; Fs_compat.remove_tree temporary) (fun () ->
    let command = Filename.concat root "ego-browser" in
    write command ego; Unix.chmod command 0o700;
    write (Filename.concat root "mode") mode;
    Filename.set_temp_dir_name temporary;
    let entered = ref false in
    Eio_main.run (fun env ->
      Time_compat.set_clock (Eio.Stdenv.clock env);
      let owner = ok (Owner.create ~incarnation:"0b000000-0000-4000-8000-000000000071") in
      ok (Owner.attach_downloads owner (ok (Broker.create ~directory:root)));
      ok (Owner.attach_uploads owner (ok (Masc.Browser_addon_uploads.create ~directory:root)));
      let dispatch command = Owner.dispatch owner {W.incarnation=Owner.incarnation owner;command} in
      let work () =
        entered := true;
        if mode = "user-owned" then (
          check bool "the worker keeps serving" false (Owner.is_retired owner);
          check bool "the exact unavailability is published" true
            (match (ok (Masc.Browser_addon_observation.decode_snapshot (Owner.snapshot owner))).unavailable with
             | [Masc.Browser_addon_observation.Ego_user_owned_name {space="masc";observed_at}] -> observed_at > 0.
             | [] | _::_ -> false);
          check bool "the SDK child has exited before serving" true
            (List.for_all (fun text -> not (running (int_of_string text))) (lines (Filename.concat root "processes")));
          check (array string) "its temporary directory is gone before serving" [||] (Sys.readdir temporary);
          check bool "the remaining worker retires normally" true (dispatch W.Retire = W.Receipt))
        else (
        let client = match B.connected_clients () with [client] -> client | _ -> fail "expected one ego client" in
        check string "browser" "ego_lite" (B.browser_name client.browser);
        check string "transport" "ego_task_space" (B.live_transport_to_string client.transport);
        check bool "SDK Space context reaches the owned live client" true
          (client.space=Some {B.id=51;name="SDK Space"});
        check string "ego lite's version" "0.6.0.16" client.version;
        check string "Chromium's version" "154.0.8037.44" client.engine_version;
        let issue ?(timeout_sec=B.default_timeout_sec) verb = dispatch (W.Issue {route=B.Live_route (Some client.client_id);verb;
          actor=Some "keeper/live-fixture";timeout_sec;only_if_idle=false}) in
        let tab_list = answered (issue B.Tabs_list) in
        let tab=match Yojson.Safe.Util.(tab_list |> member "data" |> to_list) with
          | [tab] -> tab | _ -> fail "expected one observed tab" in
        check int "observed tab" 1 Yojson.Safe.Util.(tab |> member "id" |> to_int);
        check bool "native Page context reaches the owned live client" true
          (Yojson.Safe.Util.member "egoPage" tab = `Assoc ["label",`String "p1";
            "targetId",`String "T1";"openedBy",`String "agent"]);
        let published_space_observation () =
          let value=match dispatch W.Snapshot with
            | W.Snapshot_result value -> value
            | W.Receipt|W.Issue_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Service_refusal _ ->
                fail "expected worker observation" in
          let published=ok (Masc.Browser_addon_observation.decode_snapshot value) in
          match published.client_rows with
          | [row] -> Yojson.Safe.Util.member "spaceObservation" row
          | _ -> fail "expected original live client" in
        check string "attachment SDK ownership is in the ordinary worker snapshot" "agent"
          Yojson.Safe.Util.(published_space_observation () |> member "ownership" |> to_string);
        let finished () = List.mem "space.finish" (lines (Filename.concat root "steps")) in
        let retirement_unconfirmed () = match dispatch W.Retire with
          | W.Service_refusal {disposition=W.Outcome_unknown;_} -> true
          | W.Service_refusal {disposition=W.Not_started;_}
          | W.Receipt|W.Issue_result _|Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _ -> false in
        let clock = Eio.Stdenv.clock env in
        if mode = "late" then (
          check bool "the caller stops waiting for a slow read" true
            (match issue ~timeout_sec:1. (B.Page_read {tab_id=Some 1;max_chars=None}) with
             | W.Issue_result (Ok B.Timed_out) -> true
             | W.Issue_result (Ok (B.Answered _ | Lane_absent | Refused _ | Rejected_before_effect _) | Error _)
             | Snapshot_result _ | Model_reply _|Extension_reply _ | Download_reply _ | Poll_result _ | Receipt | Service_refusal _ -> false);
          check string "its late result does not end the connection" (Yojson.Safe.to_string tab_list)
            (Yojson.Safe.to_string (answered (issue B.Tabs_list)));
          check bool "retirement reports retained backend" true (retirement_unconfirmed ());
          check bool "retirement preserves the task" false (finished ()))
        else if mode = "retire" then Eio.Switch.run (fun sw ->
          let reading = Eio.Fiber.fork_promise ~sw (fun () ->
            issue ~timeout_sec:5. (B.Page_read {tab_id=Some 1;max_chars=None})) in
          Eio.Time.sleep clock 0.5;
          let started = Eio.Time.now clock in
          check bool "retirement stops a running read and retains backend" true (retirement_unconfirmed ());
          check bool "within the SDK stop grace" true (Eio.Time.now clock -. started < 10.);
          check bool "retirement preserves the task" false (finished ());
          ignore (Eio.Promise.await_exn reading))
        else if mode = "recovery" then (
          let field=Yojson.Safe.Util.member in
          let workflow selector=B.Page_native_workflow (ok (B.Native_workflow.of_json (`Assoc [
            "tabId",`Int 1;"expectedUrl",`String "https://fixture.test/";"maxChars",`Int 1000;
            "steps",`List [`Assoc ["method",`String "click";"selector",`String selector]]]))) in
          let first=answered (issue (workflow "#dialog")) in
          check bool "original dialog input retains its partial outcome" true
            (field "ok" first=`Bool false && field "effectPhase" first=`String "partial");
          ignore(answered (issue (B.Page_act (B.Action.On_tab {tab_id=1;frame_path=[];
            interaction=B.Action.Accept_dialog None}))));
          let blocked=answered (issue (workflow "#continue")) in
          check bool "answering the dialog does not invent input release proof" true
            (field "ok" blocked=`Bool false && field "effectPhase" blocked=`String "not_started");
          let private_call action arguments=ok (Owner.operator owner
            (`Assoc ["action",`String action;"arguments",arguments])) in
          let view=private_call "view" (`Assoc []) in
          let action=match field "actions" view with
            | `List [action] -> action | _ -> fail "original worker has no pending-input operator form" in
          let arguments=field "arguments" action in
          check bool "attached worker form binds its original live client and Space" true
            (field "clientId" arguments=`String (B.client_id_to_string client.client_id)
              && field "spaceId" arguments=`String "51");
          let before=lines (Filename.concat root "steps") in
          let replace key value=match arguments with
            | `Assoc fields -> `Assoc ((key,`String value)::List.remove_assoc key fields)
            | _ -> fail "operator form arguments must be an object" in
          List.iter (fun arguments -> check bool "worker form rejects stale or foreign confirmation" true
            (field "outcome" (private_call "assert_input_reset" arguments)=`String "not_applied"))
            [replace "clientId" "another-client";replace "spaceId" "52";
             replace "generation" "stale";replace "confirmation" "go"];
          check bool "actual attached worker applies the exact operator assertion" true
            (field "outcome" (private_call "assert_input_reset" arguments)=`String "operator_asserted");
          check (list string) "private form and reset send no SDK commands" before
            (lines (Filename.concat root "steps"));
          let continued=answered (issue (workflow "#continue")) in
          let data=field "data" continued in
          check bool "same worker completes a distinct normal click after reset" true
            (field "ok" continued=`Bool true && field "tabId" data=`Int 1
              && field "inputReleased" data=`Bool true && field "completedEffect" data=`Bool true);
          let settled=private_call "view" (`Assoc []) in
          check bool "new input settles the attached Peer without another confirmation" true
            (field "actions" settled=`List []);
          check (list string) "original input was never replayed" ["#dialog";"#continue"]
            (lines (Filename.concat root "recovery-inputs"));
          ignore(answered (issue (B.Page_act (B.Action.Control (B.Action.Finish_space (B.Action.Keep_labels []))))));
          check bool "completed recovery fixture retires cleanly" true (dispatch W.Retire=W.Receipt))
        else (
        let shot = answered (issue (B.Page_capture {tab_id=1;options=None})) in
        check string "the screenshot" (Base64.encode_string "\137PNG\r\n\026\nfixture")
          Yojson.Safe.Util.(shot |> member "data" |> member "data" |> to_string);
        check string "a new tab" {|{"ok":true,"data":{"inputReadiness":"command_settled","tabId":2,"action":"open_tab","created":true,"url":"https://fixture.test/channel","title":"Opened","active":true}}|}
          (Yojson.Safe.to_string (answered (issue (B.Page_act (B.Action.Open_tab "https://fixture.test/channel")))));
        check string "a move on it" {|{"ok":true,"data":{"inputReadiness":"command_settled","tabId":2,"action":"goto","url":"https://fixture.test/next","title":"Moved"}}|}
          (Yojson.Safe.to_string (answered (issue (B.Page_goto {url="https://fixture.test/next";tab_id=Some 2}))));
        check string "a click" {|{"ok":true,"data":{"inputReadiness":"command_settled","tabId":1,"action":"click","selector":"#send","urlBefore":"https://fixture.test/","url":"https://fixture.test/","title":"Fixture"}}|}
          (Yojson.Safe.to_string (answered (issue (B.Page_interact {tab_id=1;expected_url=Some "https://fixture.test/";frame_path=[];action=B.Click "#send"}))));
        check string "where ego clicked, and the label beside its cursor names the actor"
          {|["#send", "MASC \u00b7 keeper/live-fixture \u00b7 click"]|} (read (Filename.concat root "clicked"));
        let workflow=ok (B.Native_workflow.of_json (`Assoc ["tabId",`Int 1;
          "expectedUrl",`String "https://fixture.test/";"steps",`List [];"maxChars",`Int 1000])) in
        let receipt=answered (issue ~timeout_sec:0.001 (B.Page_native_workflow workflow)) in
        check string "SDK-owned wait outlives the transport reply window" "root"
          Yojson.Safe.Util.(receipt |> member "data" |> member "snapshot" |> to_string);
        check string "composition action contract" "workflow"
          Yojson.Safe.Util.(receipt |> member "data" |> member "action" |> to_string);
        check string "composition starting URL contract" "https://fixture.test/"
          Yojson.Safe.Util.(receipt |> member "data" |> member "urlBefore" |> to_string);
        (* A download the page saved reaches the caller as a grant of this
           connection's route, never as a path, and is published from it. *)
        let actor = "keeper/live-fixture" and route = B.Live_route (Some client.client_id)
        and verb = B.Page_downloads {tab_id=1} in
        let row = match Yojson.Safe.Util.(answered (issue verb) |> member "data" |> member "downloads" |> to_list) with
          | [row] -> row | rows -> failf "%d downloads were listed" (List.length rows) in
        check bool "the worker keeps the file's path" true (Yojson.Safe.Util.member "path" row = `Null);
        let id = Yojson.Safe.Util.(row |> member "artifact" |> member "downloadGrant" |> to_string) in
        (match dispatch (W.Download_claim {id;actor;route;verb}) with
         | W.Download_reply (Broker.Snapshot descriptor) ->
           let snapshot = ok (Broker.snapshot_path ~directory:root ~snapshot_id:descriptor.snapshot_id) in
           check string "the snapshot holds what the page saved" "report" (read snapshot);
           let receipt = ok (Masc.Browser_download_artifact.publish ~base_path:root snapshot) in
           check bool "the publication is committed" true (dispatch (W.Download_commit {id;actor;route;verb;receipt}) = W.Receipt);
           check bool "and the grant released" true (dispatch (W.Download_release {id;actor;route;verb}) = W.Receipt)
         | W.Download_reply (Broker.Published _) | W.Issue_result _ | Snapshot_result _ | Model_reply _|Extension_reply _
         | Poll_result _ | Receipt | Service_refusal _ -> fail "the grant was not claimed for this connection");
        (* An upload staged for this connection's route reaches ego as the
           worker's own copies, and they stay until the space has ended. *)
        let source = Filename.concat root "note.txt" in
        write source "hello"; Unix.chmod source 0o600;
        let upload = B.Page_act (B.Action.On_tab {tab_id=1;frame_path=[];interaction=B.Action.Upload {target=B.Action.File_input "#file";paths=[source]}}) in
        let grant = "0b000000-0000-4000-8000-000000000072" in
        check bool "the upload is staged for this connection" true
          (dispatch (W.Upload_stage {id=grant;actor;route;verb=upload}) = W.Receipt);
        (match Owner.dispatch_upload owner ~id:grant ~actor ~route ~verb:upload with
         | W.Issue_result (Ok (B.Answered json)) ->
           check string "the staged files handed to the SDK" {|[{"name":"note.txt","size":5}]|}
             (Yojson.Safe.to_string Yojson.Safe.Util.(json |> member "data" |> member "chosen"))
         | W.Issue_result (Ok (B.Lane_absent | Timed_out | Refused _ | Rejected_before_effect _)) | W.Issue_result (Error _)
         | Snapshot_result _ | Model_reply _|Extension_reply _ | Download_reply _ | Poll_result _ | Receipt | Service_refusal _ ->
           fail "the staged upload did not reach ego");
        let copies = List.map Yojson.Safe.Util.to_string
            (Yojson.Safe.Util.to_list (Yojson.Safe.from_string (read (Filename.concat root "uploaded")))) in
        check bool "ego was given the worker's copies" true
          (copies <> [source] && List.for_all Sys.file_exists copies);
        let activated=answered (issue (B.Page_interact {tab_id=1;expected_url=Some "https://fixture.test/";frame_path=[];action=B.Activate_tab})) in
        let activation_data=Yojson.Safe.Util.member "data" activated in
        check bool "native activation crosses the worker boundary with its observed window" true
          Yojson.Safe.Util.(member "active" activation_data = `Bool true
            && member "stateAfter" (member "window" activation_data) = `String "normal");
        check bool "an input the table refuses never reaches ego" true
          (match issue (B.Page_interact {tab_id=1;expected_url=Some "https://fixture.test/";frame_path=[];action=B.Set_zoom {factor=1.5}}) with
           | W.Issue_result (Error (B.Transport_unsupported _)) -> true
           | W.Issue_result (Ok _ | Error _) | Snapshot_result _ | Model_reply _|Extension_reply _ | Download_reply _
           | Poll_result _ | Receipt | Service_refusal _ -> false);
        ignore (answered (issue (B.Page_act (B.Action.Control B.Action.Space_status))));
        check string "explicit refresh reaches ordinary connection observations" "Renamed native Space"
          Yojson.Safe.Util.(published_space_observation () |> member "spaceName" |> to_string);
        if mode="retained" then (
          check bool "retirement reports unconfirmed file cleanup" true (retirement_unconfirmed ());
          check bool "transport retirement never finishes the task" false (finished ()))
        else (
          let completed=answered (issue (B.Page_act (B.Action.Control (B.Action.Finish_space (B.Action.Keep_labels []))))) in
          check bool "explicit completion observes native Space closure" true
            Yojson.Safe.Util.(completed |> member "data" |> member "nativeReceipt" |> member "closedSpace" |> to_bool);
          check bool "explicit completion ran" true (finished ());
          check bool "retirement cleans a confirmed closed Space" true (dispatch W.Retire = W.Receipt));
        check bool "no client is left" true (B.connected_clients () = []))) in
      let failure = try Ego.run ~env ~owner ~downloads:(Broker.downloads_directory ~directory:root) {command; space=Browser_configuration.Named_space "masc"} work; None with
        | Invalid_argument detail | Sys_error detail -> Some detail in
      (match mode, failure with
       | ("normal" | "retained" | "late" | "retire" | "recovery" | "user-owned"), None -> ()
       | ("normal" | "retained" | "late" | "retire" | "recovery" | "user-owned"), Some detail -> failf "the connection failed: %s" detail
       | ("no-version" | "in-use" | "inspect-fails-in-use"), Some detail ->
         check bool "says why" true
           (String_util.contains_substring detail (if mode = "no-version" then "not signed in" else "EGO_TASK_SPACE_NAME_IN_USE"))
       | _, None -> failf "%s started" mode
       | _, Some detail -> failf "%s: %s" mode detail);
      check bool "owner input is fenced at the end" true (Owner.is_retired owner));
    let steps = lines (Filename.concat root "steps") in
    let processes = List.length (lines (Filename.concat root "processes")) in
    check (array string) "nothing is left of the screenshot directory" [||] (Sys.readdir temporary);
    match mode with
    | "recovery" ->
      check bool "recovery caller work ran" true !entered;
      check int "same session process handles recovery and resumed input" 1 processes;
      check int "only original and new input reached the SDK workflow" 2
        (List.length (List.filter (String.equal "page.native_workflow") steps));
      check int "dialog was answered once" 1 (List.length (List.filter (String.equal "page.dialog") steps))
    | "normal"|"retained" ->
      check bool "caller work ran" true !entered;
      let dispatched name = List.length (List.filter (String.equal name) steps) in
      check int "the native selector input is dispatched once" 1 (dispatched "page.target_input");
      check int "the native workflow is dispatched once" 1 (dispatched "page.native_workflow");
      check int "selector input has no extra DOM target resolution" 0 (dispatched "page.target");
      check int "selector input has no MASC coordinate replay" 0 (dispatched "page.pointer");
      check int "one ego process ran them all" 1 processes;
      check bool "only confirmed closure removes the published download" (mode="retained")
        (Sys.file_exists (read (Filename.concat root "downloaded")));
      check bool "upload copies require confirmed closure" (mode="retained")
        (List.exists (fun copy -> Sys.file_exists (Yojson.Safe.Util.to_string copy))
           (Yojson.Safe.Util.to_list (Yojson.Safe.from_string (read (Filename.concat root "uploaded")))));
      check bool "the screenshot directory is removed, with what a stopped capture left" false
        (Sys.file_exists (read (Filename.concat root "captures")))
    | "late" ->
      check bool "caller work ran" true !entered;
      check (list string) "steps" ["space.inspect"; "space.open"; "tabs.list"; "page.read"; "tabs.list"] steps;
      check int "a late answer keeps the process" 1 processes
    | "retire" ->
      check bool "caller work ran" true !entered;
      check (list string) "steps" ["space.inspect"; "space.open"; "tabs.list"; "page.read"] steps;
      check int "no process restarts merely to finish" 1 processes
    | "no-version" ->
      check bool "caller work never ran" false !entered;
      check (list string) "no script ran" [] steps;
      check int "no session process started" 0 processes
    | "user-owned" ->
      check bool "caller work ran" true !entered;
      check (list string) "only the read-only inspection ran" ["space.inspect"] steps;
      check int "one inspected SDK process was joined" 1 processes
    | _ ->
      check bool "caller work never ran" false !entered;
      check (list string) "an inconclusive or stale listing preserves the open refusal" ["space.inspect";"space.open"] steps)

(* An earlier case's process manager leaves a SIGCHLD handler that interrupts this wait. *)
let rec reaped pid = match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> reaped pid
let child mode () =
  let pid = Unix.create_process Sys.executable_name [|Sys.executable_name;"--case";mode|] Unix.stdin Unix.stdout Unix.stderr in
  check bool ("isolated ego case " ^ mode) true (reaped pid = Unix.WEXITED 0)

let () =
  if Array.length Sys.argv = 3 && Sys.argv.(1) = "--case" then scenario Sys.argv.(2)
  else run "browser_addon_live_ego" [
    "ego", [
      test_case "the table names a command and a space" `Quick test_the_table_names_a_command_and_a_space;
      test_case "a run answers both streams, or why not" `Quick test_a_run_answers_both_streams_or_why_not;
      test_case "a stopped run answers within the peer's window" `Quick test_a_stopped_run_answers_within_the_peers_window;
      test_case "one process runs the connection's commands" `Quick test_one_process_runs_the_connections_commands;
      test_case "a cancelled start stops its process" `Quick test_a_cancelled_start_stops_its_process;
      test_case "a start on a cancelled connection starts nothing" `Quick test_a_start_on_a_cancelled_connection_starts_nothing;
      test_case "explicit completion permits worker file cleanup" `Quick (child "normal");
      test_case "retirement preserves Space and browser-backed files" `Quick (child "retained");
      test_case "attached worker operator reset resumes real input without replay" `Quick (child "recovery");
      test_case "a result delivered after the caller stopped waiting does not end the connection" `Quick (child "late");
      test_case "retirement stops a running command and preserves the Space" `Quick (child "retire");
      test_case "an ego that names no version fails the start" `Quick (child "no-version");
      test_case "a user-owned name leaves the owner serving after SDK cleanup" `Quick (child "user-owned");
      test_case "a stale listing preserves the SDK refusal" `Quick (child "in-use");
      test_case "an unreadable listing preserves the SDK refusal" `Quick (child "inspect-fails-in-use") ] ]
