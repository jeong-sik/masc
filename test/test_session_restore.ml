(** Actual agent-directory discovery and session/notification continuity.
    Authored scenarios; no server, controller, model or TUI is launched. *)
open Alcotest
module Session = Masc.Session

let with_temp_base f =
  let path = Filename.temp_file "masc-agent-restore-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  let base = Unix.realpath path in
  let rec remove path =
    match Unix.lstat path with
    | {Unix.st_kind=Unix.S_DIR;_} ->
        Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
    | {Unix.st_kind=(Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK);_} ->
        Unix.unlink path
    | exception Unix.Unix_error (Unix.ENOENT,_,_) -> () in
  Fun.protect ~finally:(fun () -> remove base) (fun () -> f base)

let write path bytes =
  Out_channel.with_open_bin path (fun output -> output_string output bytes)

let require_session registry name =
  match Session.get_session registry ~agent_name:name with
  | Some session -> session
  | None -> fail ("missing restored agent " ^ name)

let check_message registry name expected =
  match Session.pop_message registry ~agent_name:name with
  | Some json -> check bool "original notification remains consumable" true (json = expected)
  | None -> fail "restore lost the original queued notification"

let test_direct_discovery_retains_live_state () = with_temp_base @@ fun base ->
  (* The original contract discovers names, without parsing entry contents or
     following each entry. Keep real non-file entries and a broken symlink. *)
  write (Filename.concat base "live.json") "not JSON: contents are not authority";
  write (Filename.concat base "peer.json") "";
  write (Filename.concat base "suffix.json.json") "";
  write (Filename.concat base "ignored.JSON") "";
  write (Filename.concat base "notes") "";
  Unix.mkdir (Filename.concat base "directory.json") 0o700;
  Unix.symlink (Filename.concat base "absent-target") (Filename.concat base "alias.json");
  let registry = Session.create () in
  let (_ : Session.session) = Session.register registry ~agent_name:"live" in
  Session.update_activity registry ~agent_name:"live" ~is_listening:true ();
  let live = require_session registry "live" in
  let event = `Assoc ["type",`String "restore-continuity";"payload",`String "original"] in
  ignore (Session.push_notification_to_active_agents registry ~event);
  Session.restore_from_disk registry ~agents_path:base;
  check (list string) "actual name discovery preserves original suffix policy"
    ["alias";"directory";"live";"peer";"suffix.json"]
    (List.sort String.compare (Session.connected_agents registry));
  check bool "live session object survives discovery" true (require_session registry "live" == live);
  check bool "listening state retained" true (require_session registry "live").is_listening;
  check_message registry "live" event;
  let peer = require_session registry "peer" in
  let next = `Assoc ["type",`String "restore-continuity";"payload",`String "after-first-restore"] in
  ignore (Session.push_notification_to_active_agents registry ~event:next);
  Session.restore_from_disk registry ~agents_path:base;
  check bool "repeated restore keeps the first restored peer and its queue" true
    (require_session registry "peer" == peer);
  check_message registry "peer" next

let test_actor_discovery_retains_new_connection_and_notification () = with_temp_base @@ fun base ->
  write (Filename.concat base "live.json") "";
  write (Filename.concat base "peer.json") "";
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let registry = Session.create () in
  Session.start_loop registry ~sw;
  let discovery = Eio.Fiber.fork_promise ~sw (fun () ->
    Session.restore_from_disk registry ~agents_path:base) in
  let live = Session.register registry ~agent_name:"live" in
  let received = Session.push_message registry ~from_agent:"sender"
    ~content:"original notification during restoration" ~mention:(Some "live") in
  check (list string) "actual direct message accepted by original live agent" ["live"] received;
  Eio.Promise.await_exn discovery;
  check bool "connection registered around discovery retains its queue identity" true
    (require_session registry "live" == live);
  (match Session.pop_message registry ~agent_name:"live" with
   | Some json ->
       check bool "accepted original message survives restore" true
         (Yojson.Safe.Util.member "content" json
          = `String "original notification during restoration")
   | None -> fail "accepted original message disappeared during restoration");
  let (_ : Session.session) = require_session registry "peer" in
  (* Scheduling may complete discovery before registration. Both orders must
     preserve the actual accepted message; no timing/overlap assertion is made. *)
  ()

let test_missing_and_nondirectory_preserve_live_queue () = with_temp_base @@ fun base ->
  let missing = Filename.concat base "missing" and regular = Filename.concat base "regular" in
  write regular "not a directory";
  let registry = Session.create () in
  let live = Session.register registry ~agent_name:"live" in
  let event = `Assoc ["payload",`String "retained through no-op restores"] in
  ignore (Session.push_notification_to_active_agents registry ~event);
  Session.restore_from_disk registry ~agents_path:missing;
  Session.restore_from_disk registry ~agents_path:regular;
  check bool "missing/non-directory discovery keeps live identity" true
    (require_session registry "live" == live);
  check (list string) "no phantom names from absent/non-directory resource" ["live"]
    (Session.connected_agents registry);
  check_message registry "live" event

let test_cancelled_entry_does_not_dispatch_restore () = with_temp_base @@ fun base ->
  write (Filename.concat base "unadmitted.json") "";
  let registry = Session.create () in
  Eio_main.run @@ fun _env ->
  let exception Stop_restore in
  let cancelled = try
    Eio.Switch.run (fun sw ->
      Eio.Switch.fail sw Stop_restore;
      Session.restore_from_disk registry ~agents_path:base);
    false
  with Stop_restore | Eio.Cancel.Cancelled _ -> true in
  check bool "already-cancelled caller cannot enter discovery" true cancelled;
  check (list string) "cancelled entry adds no agent session" [] (Session.connected_agents registry);
  Session.restore_from_disk registry ~agents_path:base;
  let (_ : Session.session) = require_session registry "unadmitted" in
  ()

let () =
  run "session_restore"
    ["directory and notification lifecycle",
      [test_case "direct discovery and repeat restore keep live queue and state" `Quick
         test_direct_discovery_retains_live_state;
       test_case "actor discovery keeps a real new connection and accepted message" `Quick
         test_actor_discovery_retains_new_connection_and_notification;
       test_case "missing and non-directory paths retain actual live queue" `Quick
         test_missing_and_nondirectory_preserve_live_queue;
       test_case "already-cancelled entry does not dispatch, fresh discovery succeeds" `Quick
         test_cancelled_entry_does_not_dispatch_restore]]
