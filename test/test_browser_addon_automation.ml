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
import argparse,http.server,json
p=argparse.ArgumentParser()
p.add_argument("--host");p.add_argument("--port",type=int)
p.add_argument("--websocket-port");p.add_argument("--profile-root")
a=p.parse_args()
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        assert self.path=="/status",self.path
        body=json.dumps({"value":{"ready":True}}).encode()
        self.send_response(200);self.send_header("Content-Length",str(len(body)))
        self.end_headers();self.wfile.write(body)
http.server.HTTPServer((a.host,a.port),Handler).serve_forever()
|}
let scenario ~cancel_receipt () = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let slot=Filename.temp_dir "browser-owned-slot-" "" in
  let executable=Filename.temp_file "browser-owned-driver-" ".py" in
  Out_channel.with_open_bin executable (fun out -> output_string out driver);Unix.chmod executable 0o700;
  let instance_id=Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
  let context=ok (Socket.context ~instance_id ~models:None ~automation:(Some {Browser_configuration.driver=executable;binary=None})) in
  let admission=lease (Native_addon_lease.prepare ~directories:[slot] ~instance_id ~cleanup_context:(Some context)) in
  let resource=ok (Socket.acquire ~admission ~directory:slot) in
  let directory=Filename.dirname (Socket.socket_path resource) in
  Eio.Switch.run (fun sw ->
    Eio.Switch.on_release sw (fun () -> Unix.unlink executable);
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
        | Issue_result _|Snapshot_result _|Model_reply _|Poll_result _|Receipt|Service_refusal _ -> false);
      check bool "private retirement joins backend cleanup" true
        (Owner.dispatch owner {W.incarnation=instance_id;command=W.Retire}=W.Receipt) in
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
  check bool "worker retained a cleanup receipt" true (Sys.file_exists (Filename.concat directory "automation-closed.json"));
  lease (Native_addon_lease.retire admission);
  ok (Socket.cleanup ~admission ~directory:slot);
  check bool "original allocation released" false (Sys.file_exists directory);
  Fs_compat.remove_tree slot)
let cancellation_child () =
  let pid=Unix.create_process Sys.executable_name [|Sys.executable_name;"--cancel-receipt"|] Unix.stdin Unix.stdout Unix.stderr in
  check bool "receipt cancellation joins cleanup" true (snd (Unix.waitpid [] pid)=Unix.WEXITED 0)
let () =
  if Array.to_list Sys.argv=[Sys.executable_name;"--cancel-receipt"] then
    run ~argv:[|Sys.executable_name|] "browser receipt cancellation" ["backend",[
      test_case "cancellation during receipt commit" `Quick (scenario ~cancel_receipt:true)]]
  else run "browser owned driver lifecycle" ["backend",[
    test_case "owned driver readiness, command and retirement" `Quick (scenario ~cancel_receipt:false);
    test_case "receipt cancellation joins cleanup" `Quick cancellation_child]]
