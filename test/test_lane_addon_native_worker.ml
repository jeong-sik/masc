open Alcotest
open Masc
module Native = Lane_addon_native_worker
module Protocol = Lane_addon_worker_protocol
let launcher = ref ""
let admission root instance_id =
  Eio_unix.run_in_systhread (fun () -> Native_addon_lease.prepare
    ~directories:[Filename.concat root "slot"] ~instance_id)
  |> (function Ok value -> value | Error error -> fail (Native_addon_lease.error_to_string error))

let server = {|import json,os,signal,sys,time
root,mode = sys.argv[1:3]
child = None
if mode == "descendant":
    child = os.fork()
    if child == 0:
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        for fd in (0,1,2): os.close(fd)
        with open(os.path.join(root,"child"),"w") as output: output.write(str(os.getpid()))
        while True: signal.pause()
with open(os.path.join(root,"spawned"),"w") as output:
    json.dump({"pid":os.getpid(),"cwd":os.getcwd(),"env":os.getenv("MASC_NATIVE_TEST")},output)
schema = {"type":"object","properties":{"value":{"type":"integer"}},
    "required":["value"],"additionalProperties":False}
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request: continue
    method = request["method"]
    if method == "initialize":
        result = {"protocolVersion":"2025-11-25","capabilities":{"tools":{}},
            "serverInfo":{"name":"native-lifecycle-fixture","version":"1"}}
    elif method == "tools/list":
        if mode == "validation_gate":
            open(os.path.join(root,"before-list-reply"),"w").close()
            while not os.path.exists(os.path.join(root,"gate-held")): time.sleep(.01)
        if mode == "discovery":
            open(os.path.join(root,"waiting"),"w").close()
            while True: time.sleep(0.01)
        result = {"tools":[{"name":"lane_observe","inputSchema":{"type":"object"}},
            {"name":"increment","inputSchema":schema,"outputSchema":schema}]}
    elif method == "tools/call":
        params = request["params"]
        with open(os.path.join(root,"calls"),"a") as output: output.write(params["name"]+"\n")
        if mode == "tool":
            open(os.path.join(root,"waiting"),"w").close()
            while True: time.sleep(0.01)
        value = {"rows":[],"coverage":[]} if params["name"] == "lane_observe" else {"value":params["arguments"]["value"]+1}
        result = {"content":[],"structuredContent":value}
    else: raise RuntimeError(method)
    print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}),flush=True)
|}

let require = function Ok value -> value | Error _ -> fail "native worker operation failed"
let contract () = require (Protocol.contract ~host_requests:false ~action_tool:None
  ~tool_invocation:Lane_addon_types.Direct ~exported_tools:["increment"]
  ~tool_hooks:[Lane_addon_types.Validate_input;Validate_output] ~max_reply_bytes:4096)
let command root mode : Native.command =
  {executable="python3";arguments=["-c";server;root;mode]}
let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path
let with_fixture run =
  let root = Filename.temp_file "addon-native-" ".dir" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () ->
    remove root) (fun () -> Eio_main.run (fun env ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () ->
        Eio.Switch.run (fun sw -> run env sw root))))
let read root name = In_channel.with_open_bin (Filename.concat root name) In_channel.input_all
let wait_for clock condition =
  let rec loop () = if condition () then () else (Eio.Time.sleep clock 0.005;loop ()) in loop ()
let marker root name () = Sys.file_exists (Filename.concat root name)
let await_release clock worker =
  let rec loop () = match Native.release worker with
    | Some (Ok receipt) -> receipt
    | Some (Error (Native.Cleanup_unconfirmed _)) | None ->
        Eio.Time.sleep clock 0.005;loop ()
    | Some (Error _) -> fail "native cleanup failed" in loop ()
let assert_released worker (receipt : Native.release) =
  check bool "release has no live foreground group" false
    (Posix_spawn_detached.group_id_has_members receipt.pid);
  check int "exports withdrawn" 0 (List.length (Native.exported_tools worker));
  check bool "stale calls cannot dispatch" true
    (match Native.call_exported_tool worker ~name:"increment" ~arguments:(`Assoc ["value",`Int 1]) with
      | Error (Native.Protocol Protocol.Stopped) -> true | _ -> false)

let native_lifecycle () = with_fixture (fun env sw root ->
  let clock = Eio.Stdenv.clock env in
  let cwd = Eio.Path.(Eio.Stdenv.fs env / root) in
  let worker = require (Native.start ~sw ~clock ~grace_seconds:0.02
    ~admission:(admission root "native-lifecycle") ~launcher:!launcher ~contract:(contract ()) ~command:(command root "descendant")
    ~cwd ~env:(Array.append (Unix.environment ()) [|"MASC_NATIVE_TEST=present"|]) ()) in
  wait_for clock (marker root "child");
  let spawned = Yojson.Safe.from_string (read root "spawned") in
  check string "native process uses requested cwd" (Unix.realpath root)
    Yojson.Safe.Util.(spawned |> member "cwd" |> to_string);
  check string "native process uses requested environment" "present"
    Yojson.Safe.Util.(spawned |> member "env" |> to_string);
  check bool "selected input middleware refuses before dispatch" true
    (match Native.call_exported_tool worker ~name:"increment" ~arguments:(`Assoc ["value",`String "bad"]) with
      | Error (Native.Protocol (Protocol.Host_refusal _)) -> true | _ -> false);
  let reply = require (Native.call_exported_tool worker ~name:"increment" ~arguments:(`Assoc ["value",`Int 4])) in
  check bool "native export uses shared output middleware" true
    (reply.structured_content = Some (`Assoc ["value",`Int 5]));
  check string "refused call never entered the actual subprocess" "increment\n" (read root "calls");
  Native.request_stop worker;
  ignore (Native.stop worker : (Native.release,Native.error) result);
  let receipt = await_release clock worker in
  check int "receipt belongs to exact started process"
    Yojson.Safe.Util.(spawned |> member "pid" |> to_int) receipt.pid;
  assert_released worker receipt)

let discovery_stop () = with_fixture (fun env sw root ->
  let clock = Eio.Stdenv.clock env in
  let created, set_created = Eio.Promise.create () in
  Eio.Switch.check sw;
  let stopped = Eio.Fiber.fork_promise ~sw (fun () ->
    let worker = Eio.Promise.await created in
    wait_for clock (marker root "waiting");
    check int "discovery publishes no exports" 0 (List.length (Native.exported_tools worker));
    Native.request_stop worker) in
  check bool "stop interrupts blocked discovery" true
    (match Native.start ~sw ~clock ~grace_seconds:0.02 ~admission:(admission root "native-discovery") ~launcher:!launcher
      ~contract:(contract ()) ~command:(command root "discovery")
      ~on_created:(fun worker -> Eio.Promise.resolve set_created worker;Ok ()) () with
      | Error Native.Stopped -> true | _ -> false);
  Eio.Promise.await_exn stopped;
  let worker = Eio.Promise.await created in
  assert_released worker (await_release clock worker))

let cancelled_call () = with_fixture (fun env sw root ->
  let clock = Eio.Stdenv.clock env in
  let worker = require (Native.start ~sw ~clock ~grace_seconds:0.02
    ~admission:(admission root "native-call-cancel") ~launcher:!launcher ~contract:(contract ()) ~command:(command root "tool") ()) in
  let cancelled = ref false in
  ignore (Eio.Fiber.first
    (fun () -> try
      ignore (Native.call_exported_tool worker ~name:"increment" ~arguments:(`Assoc ["value",`Int 4]));
      fail "blocked call unexpectedly returned"
     with Eio.Cancel.Cancelled _ as exn -> cancelled := true;raise exn)
    (fun () -> wait_for clock (marker root "waiting")) : unit);
  check bool "operation cancellation propagates" true !cancelled;
  (* No stop/request_stop here: doing so would mask the cancellation leak. *)
  assert_released worker (await_release clock worker);
  check string "effectful call was never replayed" "increment\n" (read root "calls"))

let cancelled_start () = with_fixture (fun env sw root ->
  let clock = Eio.Stdenv.clock env in
  let created, set_created = Eio.Promise.create () in
  let cancelled = ref false in
  ignore (Eio.Fiber.first
    (fun () -> try
      ignore (Native.start ~sw ~clock ~grace_seconds:0.02 ~admission:(admission root "native-start-cancel") ~launcher:!launcher
        ~contract:(contract ()) ~command:(command root "discovery")
        ~on_created:(fun worker -> Eio.Promise.resolve set_created worker;Ok ()) ());
      fail "blocked start unexpectedly returned"
     with Eio.Cancel.Cancelled _ as exn -> cancelled := true;raise exn)
    (fun () -> wait_for clock (marker root "waiting")) : unit);
  check bool "startup cancellation propagates" true !cancelled;
  let worker = Eio.Promise.await created in
  assert_released worker (await_release clock worker))

exception Owner_cancelled
let cancelled_owner () = with_fixture (fun env sw root ->
  let clock = Eio.Stdenv.clock env in
  let claim = admission root "cancelled-owner" in
  let offered,set_offered = Eio.Promise.create () in
  let leave,set_leave = Eio.Promise.create () in
  Eio.Switch.check sw;
  let owner = Eio.Fiber.fork_promise ~sw (fun () ->
    try Eio.Switch.run (fun owner_sw ->
      Eio.Promise.resolve set_offered owner_sw;
      Eio.Cancel.protect (fun () -> Eio.Promise.await leave))
    with Owner_cancelled -> ()) in
  let owner_sw = Eio.Promise.await offered in
  Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () ->
    ignore (Eio.Promise.try_resolve set_leave ());Eio.Promise.await_exn owner)) (fun () ->
    Eio.Switch.fail owner_sw Owner_cancelled;
    check bool "already-cancelled owner is refused before scheduling" true
      (try
        ignore (Native.start ~sw:owner_sw ~clock ~grace_seconds:0.02
          ~admission:claim ~launcher:!launcher ~contract:(contract ()) ~command:(command root "normal") ());
        false
       with Eio.Cancel.Cancelled _ -> true);
    check bool "cancelled owner never spawns a process" false (marker root "spawned" ());
    require (Eio_unix.run_in_systhread (fun () -> Native_addon_lease.retire claim));
    check bool "caller retains untransferred admission" true
      (Eio_unix.run_in_systhread (fun () -> Native_addon_lease.status claim)=Ok Native_addon_lease.Settled)))

let replacement_preserves_receipt () = with_fixture (fun env sw root ->
  let clock = Eio.Stdenv.clock env in
  let first = require (Native.start ~sw ~clock ~grace_seconds:0.02
    ~admission:(admission root "first") ~launcher:!launcher ~contract:(contract ())
    ~command:(command root "normal") ()) in
  let released = require (Native.stop first) in
  let second = require (Native.start ~sw ~clock ~grace_seconds:0.02
    ~admission:(admission root "second") ~launcher:!launcher ~contract:(contract ())
    ~command:(command root "normal") ()) in
  check int "historical receipt stays bound to original child" released.pid
    (require (Native.stop first)).pid;
  check bool "old calls cannot target replacement" true
    (match Native.call_exported_tool first ~name:"increment" ~arguments:(`Assoc ["value",`Int 2]) with
     | Error (Native.Protocol Protocol.Stopped) -> true | _ -> false);
  let reply = require (Native.call_exported_tool second ~name:"increment" ~arguments:(`Assoc ["value",`Int 8])) in
  check bool "replacement remains usable" true (reply.structured_content=Some (`Assoc ["value",`Int 9]));
  assert_released second (require (Native.stop second)))

let failed_retirement_still_reaps () = with_fixture (fun env sw root ->
  let clock = Eio.Stdenv.clock env in
  let claim = admission root "retirement-failure" in
  let created = ref None in
  let result = Native.start ~sw ~clock ~grace_seconds:0.02 ~admission:claim
    ~launcher:!launcher ~contract:(contract ()) ~command:(command root "normal")
    ~on_created:(fun worker ->
      created := Some worker;
      wait_for clock (marker root "spawned");
      check int "pre-discovery exports stay unavailable" 0 (List.length (Native.exported_tools worker));
      Unix.chmod (Filename.concat root "slot") 0o755;
      Error "fixture refuses publication") () in
  Unix.chmod (Filename.concat root "slot") 0o700;
  check bool "retirement failure remains unconfirmed" true
    (match result with Error (Native.Cleanup_unconfirmed _) -> true | Ok _ | Error _ -> false);
  let pid = Yojson.Safe.Util.(Yojson.Safe.from_string (read root "spawned") |> member "pid" |> to_int) in
  check bool "failed retirement does not skip group cleanup" false
    (Posix_spawn_detached.group_id_has_members pid);
  (match created with
   | {contents=Some worker} ->
       check int "failed owner exports remain revoked" 0 (List.length (Native.exported_tools worker));
       check bool "failure never becomes a release receipt" true
         (match Native.release worker with Some (Error (Native.Cleanup_unconfirmed _)) -> true | _ -> false)
   | {contents=None} -> fail "missing exact created worker");
  require (Eio_unix.run_in_systhread (fun () -> Native_addon_lease.retire claim)))

let blocked_validation_still_stops () = with_fixture (fun env sw root ->
  let clock = Eio.Stdenv.clock env in
  let claim = admission root "validation-gate" in
  let release_gate () = Out_channel.with_open_bin (Filename.concat root "release-gate")
    (fun channel -> output_string channel "release") in
  Fun.protect ~finally:release_gate (fun () ->
    let created,set_created = Eio.Promise.create () in
    Eio.Switch.check sw;
    let starting = Eio.Fiber.fork_promise ~sw (fun () ->
      Native.start ~sw ~clock ~grace_seconds:0.02 ~admission:claim ~launcher:!launcher
        ~contract:(contract ()) ~command:(command root "validation_gate")
        ~on_created:(fun worker -> Eio.Promise.resolve set_created worker;Ok ()) ()) in
    let worker = Eio.Promise.await created in
    wait_for clock (marker root "before-list-reply");
    let blocker_script = "import fcntl,pathlib,sys,time\nroot=pathlib.Path(sys.argv[1])\nf=(root/'slot'/'gate').open('r+')\nfcntl.lockf(f,fcntl.LOCK_EX)\n(root/'gate-held').write_text('held')\nwhile not (root/'release-gate').exists(): time.sleep(.01)" in
    let blocker = Eio.Process.spawn ~sw (Eio.Stdenv.process_mgr env)
      ["python3";"-c";blocker_script;root] in
    wait_for clock (marker root "gate-held");
    wait_for clock (fun () -> Native.phase worker=Native.Validating_owner);
    Native.request_stop worker;
    let pid = Yojson.Safe.Util.(Yojson.Safe.from_string (read root "spawned") |> member "pid" |> to_int) in
    wait_for clock (fun () -> not (Posix_spawn_detached.group_id_has_members pid));
    check bool "owned child exits while unrelated gate remains held" false (marker root "release-gate" ());
    check bool "blocked retirement cannot fabricate release" true (Native.release worker=None);
    release_gate ();
    check bool "late validation cannot restore serving" true
      (match Eio.Promise.await_exn starting with Error _ -> true | Ok _ -> false);
    assert_released worker (await_release clock worker);
    check bool "unrelated holder exits by its own release" true (Eio.Process.await blocker=`Exited 0)))

let () =
  if Array.length Sys.argv <> 2 then failwith "expected actual native Addon launcher path";
  launcher := Unix.realpath Sys.argv.(1);
  run ~argv:[|Sys.argv.(0)|] "Native Addon live process ownership"
  ["ownership",[
    test_case "shared contracts, cwd, environment and owned descendant release" `Quick native_lifecycle;
    test_case "stop interrupts actual blocked discovery" `Quick discovery_stop;
    test_case "cancelled tool call cleans up without an explicit stop" `Quick cancelled_call;
    test_case "cancelled startup cleans up without an explicit stop" `Quick cancelled_start;
    test_case "already-cancelled owner cannot leave startup pending" `Quick cancelled_owner;
    test_case "historical receipt cannot affect a replacement" `Quick replacement_preserves_receipt;
    test_case "failed retirement still reaps owned process" `Quick failed_retirement_still_reaps;
    test_case "blocked validation still stops exact child" `Quick blocked_validation_still_stops]]
