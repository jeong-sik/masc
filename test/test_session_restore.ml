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

let check_absent registry name =
  check bool ("removed agent stays absent: " ^ name) true
    (Session.get_session registry ~agent_name:name = None)

let test_direct_removal_during_discovery () = with_temp_base @@ fun base ->
  write (Filename.concat base "retired.json") "";
  write (Filename.concat base "peer.json") "";
  let registry = Session.create () in
  let live = Session.register registry ~agent_name:"live" in
  let (_ : Session.session) = Session.register registry ~agent_name:"retired" in
  let event = `Assoc ["payload",`String "survives another agent's removal"] in
  ignore (Session.push_notification_to_active_agents registry ~event);
  Session.For_testing.restore_from_disk registry ~agents_path:base
    ~after_discovery:(fun () ->
      Session.unregister registry ~agent_name:"retired";
      check_absent registry "retired");
  check_absent registry "retired";
  let (_ : Session.session) = require_session registry "peer" in
  check bool "unrelated live connection retains original queue" true
    (require_session registry "live" == live);
  check_message registry "live" event;
  (* Suppression belongs to the earlier admitted restore, not to the persisted
     name forever. This proves later admission policy, not heap reclamation. *)
  Session.restore_from_disk registry ~agents_path:base;
  let (_ : Session.session) = require_session registry "retired" in
  ()

let test_actor_transient_connection_removed_before_apply () = with_temp_base @@ fun base ->
  write (Filename.concat base "transient.json") "";
  write (Filename.concat base "peer.json") "";
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let registry = Session.create () in
  Session.start_loop registry ~sw;
  let live = Session.register registry ~agent_name:"live" in
  let event = `Assoc ["payload",`String "original live queue"] in
  ignore (Session.push_notification_to_active_agents registry ~event);
  Session.For_testing.restore_from_disk registry ~agents_path:base
    ~after_discovery:(fun () ->
      check_absent registry "transient";
      let (_ : Session.session) = Session.register registry ~agent_name:"transient" in
      check (list string) "transient real connection accepts its message" ["transient"]
        (Session.push_message registry ~from_agent:"sender" ~content:"before removal"
           ~mention:(Some "transient"));
      Session.unregister registry ~agent_name:"transient";
      (* The request/reply is a mailbox barrier after real removal. *)
      check_absent registry "transient");
  check_absent registry "transient";
  let (_ : Session.session) = require_session registry "peer" in
  check bool "unrelated live object survives owner application" true
    (require_session registry "live" == live);
  check_message registry "live" event

let test_overlapping_discoveries_respect_one_removal () = with_temp_base @@ fun base ->
  write (Filename.concat base "retired.json") "";
  write (Filename.concat base "peer.json") "";
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let registry = Session.create () in
  Session.start_loop registry ~sw;
  let (_ : Session.session) = Session.register registry ~agent_name:"retired" in
  let ready1, mark1 = Eio.Promise.create () in
  let ready2, mark2 = Eio.Promise.create () in
  let apply1, release1 = Eio.Promise.create () in
  let apply2, release2 = Eio.Promise.create () in
  let first = Eio.Fiber.fork_promise ~sw (fun () ->
    Session.For_testing.restore_from_disk registry ~agents_path:base
      ~after_discovery:(fun () -> Eio.Promise.resolve mark1 (); Eio.Promise.await apply1)) in
  let second = Eio.Fiber.fork_promise ~sw (fun () ->
    Session.For_testing.restore_from_disk registry ~agents_path:base
      ~after_discovery:(fun () -> Eio.Promise.resolve mark2 (); Eio.Promise.await apply2)) in
  Eio.Promise.await ready1;
  Eio.Promise.await ready2;
  Session.unregister registry ~agent_name:"retired";
  check_absent registry "retired";
  Eio.Promise.resolve release1 ();
  Eio.Promise.await_exn first;
  check_absent registry "retired";
  let peer = require_session registry "peer" in
  check (list string) "first restored peer accepts an actual direct message" ["peer"]
    (Session.push_message registry ~from_agent:"sender" ~content:"between restored publications"
       ~mention:(Some "peer"));
  Eio.Promise.resolve release2 ();
  Eio.Promise.await_exn second;
  check_absent registry "retired";
  check bool "second restore retains peer's already accepted queue" true
    (require_session registry "peer" == peer);
  (match Session.pop_message registry ~agent_name:"peer" with
   | Some json -> check bool "original message consumable after both restorations" true
       (Yojson.Safe.Util.member "content" json = `String "between restored publications")
   | None -> fail "overlapping restore lost peer notification");
  Session.restore_from_disk registry ~agents_path:base;
  let (_ : Session.session) = require_session registry "retired" in
  ()

let test_cancelled_after_read_does_not_publish () = with_temp_base @@ fun base ->
  write (Filename.concat base "retired.json") "";
  write (Filename.concat base "peer.json") "";
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let registry = Session.create () in
  Session.start_loop registry ~sw;
  let live = Session.register registry ~agent_name:"live" in
  let (_ : Session.session) = Session.register registry ~agent_name:"retired" in
  let event = `Assoc ["payload",`String "preserved during caller cancellation"] in
  ignore (Session.push_notification_to_active_agents registry ~event);
  let exception Stop_restore in
  let cancelled = try
    Eio.Switch.run (fun child ->
      Session.For_testing.restore_from_disk registry ~agents_path:base
        ~after_discovery:(fun () ->
          Session.unregister registry ~agent_name:"retired";
          check_absent registry "retired";
          Eio.Switch.fail child Stop_restore));
    false
  with Stop_restore | Eio.Cancel.Cancelled _ -> true in
  check bool "post-read cooperative cancellation reaches caller" true cancelled;
  check_absent registry "retired";
  check_absent registry "peer";
  check bool "cancellation leaves unrelated live queue intact" true
    (require_session registry "live" == live);
  check_message registry "live" event;
  Session.restore_from_disk registry ~agents_path:base;
  let (_ : Session.session) = require_session registry "retired" in
  let (_ : Session.session) = require_session registry "peer" in
  ()

let test_actor_release_rejects_late_read_after_restart () = with_temp_base @@ fun base ->
  write (Filename.concat base "late.json") "";
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun outer ->
  let registry = Session.create () in
  let live = Session.register registry ~agent_name:"live" in
  let event = `Assoc ["payload",`String "live queue across actor lifetimes"] in
  ignore (Session.push_notification_to_active_agents registry ~event);
  let started, mark_started = Eio.Promise.create () in
  let stop, release_actor = Eio.Promise.create () in
  let first_actor = Eio.Fiber.fork_promise ~sw:outer (fun () ->
    Eio.Switch.run (fun sw ->
      Session.start_loop registry ~sw;
      Eio.Promise.resolve mark_started ();
      Eio.Promise.await stop)) in
  Eio.Promise.await started;
  let discovered, mark_discovered = Eio.Promise.create () in
  let apply, release_read = Eio.Promise.create () in
  let old_restore = Eio.Fiber.fork_promise ~sw:outer (fun () ->
    try
      Session.For_testing.restore_from_disk registry ~agents_path:base
        ~after_discovery:(fun () ->
          Eio.Promise.resolve mark_discovered ();
          Eio.Promise.await apply);
      false
    with Session.Registry_closed -> true) in
  Eio.Promise.await discovered;
  Eio.Promise.resolve release_actor ();
  Eio.Promise.await_exn first_actor;
  Eio.Switch.run (fun sw ->
    Session.start_loop registry ~sw;
    Eio.Promise.resolve release_read ();
    check bool "old actor's unclaimed read rejected after restart" true
      (Eio.Promise.await_exn old_restore);
    check_absent registry "late";
    check bool "late rejection preserves original live session" true
      (require_session registry "live" == live);
    check_message registry "live" event;
    Session.restore_from_disk registry ~agents_path:base;
    let (_ : Session.session) = require_session registry "late" in
    ())

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
         test_cancelled_entry_does_not_dispatch_restore;
       test_case "direct removal after actual discovery survives owner merge" `Quick
         test_direct_removal_during_discovery;
       test_case "transient real connection removed before owner apply stays absent" `Quick
         test_actor_transient_connection_removed_before_apply;
       test_case "two real discoveries retain one removal and peer notification" `Quick
         test_overlapping_discoveries_respect_one_removal;
       test_case "post-read cancellation leaves live notification and permits fresh restore" `Quick
         test_cancelled_after_read_does_not_publish;
       test_case "actor release rejects late read after restart and permits fresh restore" `Quick
         test_actor_release_rejects_late_read_after_restart]]
