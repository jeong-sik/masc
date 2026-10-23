open Alcotest
module Ego = Masc.Browser_addon_live_ego
module Peer = Masc.Browser_ego_peer
module Owner = Masc.Browser_addon_owner
module W = Masc.Browser_addon_wire
module B = Browser_lane
let ok = function Ok value -> value | Error detail -> fail detail
let write path text = Out_channel.with_open_bin path (fun channel -> output_string channel text)
let read path = In_channel.with_open_bin path In_channel.input_all
let lines path = if Sys.file_exists path then List.filter ((<>) "") (String.split_on_char '\n' (read path)) else []

let configuration text = Browser_configuration.parse (Otoml.Parser.from_string text)
let test_the_table_names_a_command_and_a_space () =
  (match configuration "[browser.live.ego]\ncommand = \"/opt/ego-browser\"\nspace = \"masc\"\n" with
   | Ok {Browser_configuration.live_ego = Some {command; space}; _} ->
     check string "command" "/opt/ego-browser" command; check string "space" "masc" space
   | Ok _ -> fail "the ego table was not read"
   | Error detail -> fail detail);
  (match configuration "[browser.live]\nenabled = true\n" with
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
      "browser.live.ego.space must be a non-empty task space name";
      "an unknown key", "[browser.live.ego]\ncommand = \"/opt/ego-browser\"\nspace = \"masc\"\nprofile = \"x\"\n",
      "browser.live.ego.profile is not a supported setting" ];
  check (list string) "the worker's arguments" ["--live-ego-command";"/opt/ego-browser";"--live-ego-space";"masc"]
    (Ego.arguments {command="/opt/ego-browser";space="masc"})

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
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let window_s = 2.5 in
      let started = Eio.Time.now clock in
      check string "the run" "timed out" (match Ego.runner ~env ~command ~window_s "" with
        | Ok _ -> "answered" | Error failure -> failure_name failure);
      (* Stopping it spends the stop grace inside the window, not after it. *)
      check bool "within the window" true (Eio.Time.now clock -. started < window_s +. 0.5)))

(* ego-browser as the worker runs it: [--version], and [nodejs] with one
   fixed script on stdin, answered by the step its first line names. *)
let ego = {|#!/usr/bin/env python3
import json,pathlib,sys,time
root=pathlib.Path(__file__).resolve().parent
mode=(root/'mode').read_text()
if sys.argv[1:]==['--version']:
    if mode=='no-version':
        print('ego-browser: not signed in');sys.exit(3)
    print('ego-browser 0.6.0.16\n  chromium 154.0.8037.44\n  node v24.21.0');sys.exit(0)
assert sys.argv[1:]==['nodejs'],sys.argv
lines=sys.stdin.read().split('\n')
step=lines[0].removeprefix('// masc-ego: ')
args=json.loads(next(l for l in lines if l.startswith('const args = ')).removeprefix('const args = ').removesuffix(';'))
with open(root/'steps','a') as log:log.write(step+'\n')
def answer(value=None,error=None):
    frame={'ok':True,'value':value} if error is None else {'ok':False,'error':error}
    sys.stderr.write('masc-ego-result '+json.dumps(frame)+'\n')
state=json.dumps({'url':'https://fixture.test/','title':'Fixture','viewport':{'width':800,'height':600}})
if step=='space.open':
    if mode=='in-use':answer(error='EGO_TASK_SPACE_NAME_IN_USE: masc')
    else:answer({'spaceId':51,'ownership':'agent'})
elif step=='tabs.list':
    answer([{'label':'p1','targetId':'T1','title':'Fixture','url':'https://fixture.test/','active':True}])
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
elif step=='space.finish':answer(None)
else:answer(error='unexpected step '+step)
|}

let answered = function
  | W.Issue_result (Ok (B.Answered json)) -> json
  | W.Issue_result (Ok (B.Lane_absent | Timed_out | Refused _ | Rejected_before_effect _)) | W.Issue_result (Error _)
  | Snapshot_result _ | Model_reply _ | Download_reply _ | Poll_result _ | Receipt | Service_refusal _ ->
    fail "the ego connection did not answer"

let scenario mode =
  let root = Unix.realpath (Filename.temp_dir ~perms:0o700 "owned-live-ego-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let command = Filename.concat root "ego-browser" in
    write command ego; Unix.chmod command 0o700;
    write (Filename.concat root "mode") mode;
    (* The connection's screenshot directory is made here, so what is left
       of it after the run can be seen. *)
    let temporary = Filename.concat root "tmp" in
    Unix.mkdir temporary 0o700; Filename.set_temp_dir_name temporary;
    let entered = ref false in
    Eio_main.run (fun env ->
      Time_compat.set_clock (Eio.Stdenv.clock env);
      let owner = ok (Owner.create ~incarnation:"0b000000-0000-4000-8000-000000000071") in
      let dispatch command = Owner.dispatch owner {W.incarnation=Owner.incarnation owner;command} in
      let work () =
        entered := true;
        let client = match B.connected_clients () with [client] -> client | _ -> fail "expected one ego client" in
        check string "browser" "ego_lite" (B.browser_name client.browser);
        check string "transport" "ego_task_space" (B.live_transport_to_string client.transport);
        check string "ego lite's version" "0.6.0.16" client.version;
        check string "Chromium's version" "154.0.8037.44" client.engine_version;
        let issue ?(timeout_sec=B.default_timeout_sec) verb = dispatch (W.Issue {route=B.Live_route (Some client.client_id);verb;
          actor=Some "keeper/live-fixture";timeout_sec;only_if_idle=false}) in
        let tab_list = answered (issue B.Tabs_list) in
        check string "the tab list" {|{"ok":true,"data":[{"id":1,"index":0,"url":"https://fixture.test/","title":"Fixture","active":true}]}|}
          (Yojson.Safe.to_string tab_list);
        let finished () = List.mem "space.finish" (lines (Filename.concat root "steps")) in
        let clock = Eio.Stdenv.clock env in
        if mode = "late" then (
          check bool "the caller stops waiting for a slow read" true
            (match issue ~timeout_sec:1. (B.Page_read {tab_id=Some 1;max_chars=None}) with
             | W.Issue_result (Ok B.Timed_out) -> true
             | W.Issue_result (Ok (B.Answered _ | Lane_absent | Refused _ | Rejected_before_effect _) | Error _)
             | Snapshot_result _ | Model_reply _ | Download_reply _ | Poll_result _ | Receipt | Service_refusal _ -> false);
          check string "its late result does not end the connection" (Yojson.Safe.to_string tab_list)
            (Yojson.Safe.to_string (answered (issue B.Tabs_list)));
          check bool "retirement" true (dispatch W.Retire = W.Receipt);
          check bool "retirement answers after the space ended" true (finished ()))
        else if mode = "retire" then Eio.Switch.run (fun sw ->
          let reading = Eio.Fiber.fork_promise ~sw (fun () ->
            issue ~timeout_sec:5. (B.Page_read {tab_id=Some 1;max_chars=None})) in
          Eio.Time.sleep clock 0.5;
          let started = Eio.Time.now clock in
          check bool "retirement stops a running read" true (dispatch W.Retire = W.Receipt);
          check bool "within the stop grace and the space's end" true (Eio.Time.now clock -. started < 10.);
          check bool "retirement answers after the space ended" true (finished ());
          ignore (Eio.Promise.await_exn reading))
        else (
        let shot = answered (issue (B.Page_capture {tab_id=1})) in
        check string "the screenshot" (Base64.encode_string "\137PNG\r\n\026\nfixture")
          Yojson.Safe.Util.(shot |> member "data" |> member "data" |> to_string);
        check string "a new tab" {|{"ok":true,"data":{"tabId":2,"action":"open_tab","created":true,"url":"https://fixture.test/channel","title":"Opened","active":true}}|}
          (Yojson.Safe.to_string (answered (issue (B.Page_act (B.Action.Open_tab "https://fixture.test/channel")))));
        check string "a move on it" {|{"ok":true,"data":{"tabId":2,"action":"goto","url":"https://fixture.test/next","title":"Moved"}}|}
          (Yojson.Safe.to_string (answered (issue (B.Page_goto {url="https://fixture.test/next";tab_id=Some 2}))));
        check bool "an input the table refuses never reaches ego" true
          (match issue (B.Page_interact {tab_id=1;expected_url=None;frame_path=[];action=B.Click "#send"}) with
           | W.Issue_result (Error (B.Transport_unsupported _)) -> true
           | W.Issue_result (Ok _ | Error _) | Snapshot_result _ | Model_reply _ | Download_reply _
           | Poll_result _ | Receipt | Service_refusal _ -> false);
        check bool "retirement ends the task space" true (dispatch W.Retire = W.Receipt);
        check bool "retirement answers after the space ended" true (finished ());
        check bool "no client is left" true (B.connected_clients () = [])) in
      let failure = try Ego.run ~env ~owner {command; space="masc"} work; None with
        | Invalid_argument detail | Sys_error detail -> Some detail in
      (match mode, failure with
       | ("normal" | "late" | "retire"), None -> ()
       | ("normal" | "late" | "retire"), Some detail -> failf "the connection failed: %s" detail
       | ("no-version" | "in-use"), Some detail ->
         check bool "says why" true
           (String_util.contains_substring detail (if mode = "in-use" then "EGO_TASK_SPACE_NAME_IN_USE" else "not signed in"))
       | _, None -> failf "%s started" mode
       | _, Some detail -> failf "%s: %s" mode detail);
      check bool "owner input is fenced at the end" true (Owner.is_retired owner));
    let steps = lines (Filename.concat root "steps") in
    check (array string) "nothing is left of the screenshot directory" [||] (Sys.readdir temporary);
    match mode with
    | "normal" ->
      check bool "caller work ran" true !entered;
      check (list string) "steps" ["space.open"; "tabs.list"; "page.capture"; "page.open"; "page.goto"; "space.finish"] steps;
      check bool "the screenshot directory is removed, with what a stopped capture left" false
        (Sys.file_exists (read (Filename.concat root "captures")))
    | "late" ->
      check bool "caller work ran" true !entered;
      check (list string) "steps" ["space.open"; "tabs.list"; "page.read"; "tabs.list"; "space.finish"] steps
    | "retire" ->
      check bool "caller work ran" true !entered;
      check (list string) "steps" ["space.open"; "tabs.list"; "page.read"; "space.finish"] steps
    | "no-version" ->
      check bool "caller work never ran" false !entered;
      check (list string) "no script ran" [] steps
    | _ ->
      check bool "caller work never ran" false !entered;
      check (list string) "only the open ran" ["space.open"] steps)

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
      test_case "the worker serves the space until retirement" `Quick (child "normal");
      test_case "a result delivered after the caller stopped waiting does not end the connection" `Quick (child "late");
      test_case "retirement stops a running command and ends the space" `Quick (child "retire");
      test_case "an ego that names no version fails the start" `Quick (child "no-version");
      test_case "a space the operator holds fails the start" `Quick (child "in-use") ] ]
