(** Tests for Workspace_eio: OCaml 5.x Eio-native Workspace implementation *)

(* Initialize RNG before any crypto operations *)
let () = Mirage_crypto_rng_unix.use_default ()


(** Recursive directory cleanup *)
let rec rm_rf path =
  if Sys.file_exists path then begin
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Unix.unlink path
  end

(** Generate unique test directory - deterministic using PID + timestamp *)
let make_test_dir () =
  let unique_id = Printf.sprintf "masc_workspace_eio_test_%d_%d"
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1000000.)) in
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ()) unique_id in
  (try Unix.mkdir tmp_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  tmp_dir

(** Run test with Eio environment *)
let with_eio_env f =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let tmp_dir = make_test_dir () in
  let config = Workspace_eio.test_config ~fs tmp_dir in
  Fun.protect
    ~finally:(fun () -> try rm_rf tmp_dir with _ -> ())
    (fun () -> f config)

(** {1 Agent Tests} *)

let test_register_agent () =
  with_eio_env @@ fun config ->
  match Workspace_eio.register_agent config ~name:"claude" () with
  | Ok agent ->
      Alcotest.(check string) "agent name" "claude" agent.name;
      Alcotest.(check string) "agent status" "active" agent.status
  | Error e ->
      Alcotest.failf "register_agent failed: %s" e

let test_get_agent () =
  with_eio_env @@ fun config ->
  (* Register first *)
  let _ = Workspace_eio.register_agent config ~name:"gemini" ~capabilities:["code"; "review"] () in

  (* Get agent *)
  match Workspace_eio.get_agent config ~name:"gemini" with
  | Ok agent ->
      Alcotest.(check string) "agent name" "gemini" agent.name;
      Alcotest.(check (list string)) "capabilities" ["code"; "review"] agent.capabilities
  | Error e ->
      Alcotest.failf "get_agent failed: %s" e

let test_remove_agent () =
  with_eio_env @@ fun config ->
  (* Register *)
  let _ = Workspace_eio.register_agent config ~name:"codex" () in

  (* Remove *)
  (match Workspace_eio.remove_agent config ~name:"codex" with
   | Ok () -> ()
   | Error e -> Alcotest.failf "remove_agent failed: %s" e);

  (* Verify removed *)
  match Workspace_eio.get_agent config ~name:"codex" with
  | Error _ -> ()  (* Expected: not found *)
  | Ok _ -> Alcotest.fail "agent should have been removed"

let test_remove_missing_agent_is_noop () =
  with_eio_env @@ fun config ->
  (match Workspace_eio.remove_agent config ~name:"missing" with
   | Ok () -> ()
   | Error e -> Alcotest.failf "remove_agent failed: %s" e);

  let events = Workspace_eio.get_recent_events config ~limit:10 in
  Alcotest.(check int) "no leave event for already missing agent" 0
    (List.length events)

let test_get_event_result_surfaces_decode_error () =
  with_eio_env @@ fun config ->
  let event =
    Workspace_eio.log_event
      config
      ~event_type:Workspace_eio.Broadcast
      ~agent:"tester"
      ~payload:(`Assoc [ "message", `String "hello" ])
  in
  let key = Workspace_eio.event_key event.event_seq in
  (match Backend.FileSystem.set config.backend key "{not-json" with
   | Ok () -> ()
   | Error err ->
     Alcotest.failf
       "failed to corrupt event fixture: %s"
       (Backend_types.show_error err));
  (match Workspace_eio.get_event_result config ~seq:event.event_seq with
   | Ok _ -> Alcotest.fail "expected corrupt event to surface Error"
   | Error msg ->
     Alcotest.(check bool) "decode error populated" true (String.length msg > 0));
  Alcotest.(check bool)
    "legacy get_event projects corrupt event to None"
    true
    (Option.is_none (Workspace_eio.get_event config ~seq:event.event_seq));
  Alcotest.(check int)
    "recent events skips corrupt event after logging"
    0
    (List.length (Workspace_eio.get_recent_events config ~limit:10))

(** {1 Lock Tests} *)

let test_acquire_lock () =
  with_eio_env @@ fun config ->
  match Workspace_eio.acquire_lock config ~resource:"file.txt" ~owner:"claude" with
  | Ok (Some lock) ->
      Alcotest.(check string) "lock resource" "file.txt" lock.resource;
      Alcotest.(check string) "lock owner" "claude" lock.owner
  | Ok None ->
      Alcotest.fail "lock should have been acquired"
  | Error e ->
      Alcotest.failf "acquire_lock failed: %s" e

let test_lock_conflict () =
  with_eio_env @@ fun config ->
  (* First agent acquires lock *)
  let _ = Workspace_eio.acquire_lock config ~resource:"shared.txt" ~owner:"claude" in

  (* Second agent tries to acquire same lock *)
  match Workspace_eio.acquire_lock config ~resource:"shared.txt" ~owner:"gemini" with
  | Ok None -> ()  (* Expected: lock held by claude *)
  | Ok (Some _) -> Alcotest.fail "second agent should not get lock"
  | Error e -> Alcotest.failf "unexpected error: %s" e

let test_release_lock () =
  with_eio_env @@ fun config ->
  (* Acquire *)
  let _ = Workspace_eio.acquire_lock config ~resource:"temp.txt" ~owner:"claude" in

  (* Release *)
  (match Workspace_eio.release_lock config ~resource:"temp.txt" ~owner:"claude" with
   | Ok () -> ()
   | Error e -> Alcotest.failf "release_lock failed: %s" e);

  (* Now another agent can acquire *)
  match Workspace_eio.acquire_lock config ~resource:"temp.txt" ~owner:"gemini" with
  | Ok (Some _) -> ()  (* Expected: lock now available *)
  | Ok None -> Alcotest.fail "lock should be available after release"
  | Error e -> Alcotest.failf "acquire after release failed: %s" e

(** {1 Message Tests} *)

let test_broadcast_message () =
  with_eio_env @@ fun config ->
  match Workspace_eio.broadcast config ~from_agent:"claude" ~content:"Hello world!" with
  | Ok msg ->
      Alcotest.(check bool) "seq > 0" true (msg.seq > 0);
      Alcotest.(check string) "from_agent" "claude" msg.from_agent;
      Alcotest.(check string) "content" "Hello world!" msg.content
  | Error e ->
      Alcotest.failf "broadcast failed: %s" e

let test_mention_extraction () =
  with_eio_env @@ fun config ->
  match Workspace_eio.broadcast config ~from_agent:"claude" ~content:"@gemini please review" with
  | Ok msg ->
      Alcotest.(check (option string)) "mention extracted" (Some "gemini") msg.mention
  | Error e ->
      Alcotest.failf "broadcast failed: %s" e

let test_get_message () =
  with_eio_env @@ fun config ->
  (* Broadcast first *)
  let msg_result = Workspace_eio.broadcast config ~from_agent:"claude" ~content:"Test message" in
  match msg_result with
  | Error e -> Alcotest.failf "broadcast failed: %s" e
  | Ok msg ->
      (* Get the message *)
      match Workspace_eio.get_message config ~seq:msg.seq with
      | Ok retrieved ->
          Alcotest.(check string) "content matches" "Test message" retrieved.content
      | Error e ->
          Alcotest.failf "get_message failed: %s" e

(** {1 State Tests} *)

let test_workspace_state () =
  with_eio_env @@ fun config ->
  (* Register some agents *)
  let _ = Workspace_eio.register_agent config ~name:"claude" () in
  let _ = Workspace_eio.register_agent config ~name:"gemini" () in

  (* Read state *)
  match Workspace_eio.read_state config with
  | Ok state ->
      Alcotest.(check bool) "has agents" true (List.length state.active_agents >= 2);
      Alcotest.(check bool) "not paused" false state.paused
  | Error e ->
      Alcotest.failf "read_state failed: %s" e

let test_workspace_status () =
  with_eio_env @@ fun config ->
  let _ = Workspace_eio.register_agent config ~name:"claude" () in
  let status = Workspace_eio.status config in

  let open Yojson.Safe.Util in
  Alcotest.(check bool) "has protocol_version" true
    ((status |> member "protocol_version" |> to_string) <> "")

(** {1 Health Check Tests} *)

let test_health_check () =
  with_eio_env @@ fun config ->
  match Workspace_eio.health_check config with
  | Ok result -> Alcotest.(check bool) "is healthy" true result.is_healthy
  | Error e -> Alcotest.failf "health_check failed: %s" e

let () =
  Alcotest.run "Workspace_eio" [
    "agent", [
      Alcotest.test_case "register agent" `Quick test_register_agent;
      Alcotest.test_case "get agent" `Quick test_get_agent;
      Alcotest.test_case "remove agent" `Quick test_remove_agent;
      Alcotest.test_case
        "remove missing agent is no-op"
        `Quick
        test_remove_missing_agent_is_noop;
    ];
    "event", [
      Alcotest.test_case
        "get_event_result surfaces decode error"
        `Quick
        test_get_event_result_surfaces_decode_error;
    ];
    "lock", [
      Alcotest.test_case "acquire lock" `Quick test_acquire_lock;
      Alcotest.test_case "lock conflict" `Quick test_lock_conflict;
      Alcotest.test_case "release lock" `Quick test_release_lock;
    ];
    "message", [
      Alcotest.test_case "broadcast message" `Quick test_broadcast_message;
      Alcotest.test_case "mention extraction" `Quick test_mention_extraction;
      Alcotest.test_case "get message" `Quick test_get_message;
    ];
    "state", [
      Alcotest.test_case "workspace state" `Quick test_workspace_state;
      Alcotest.test_case "project status" `Quick test_workspace_status;
    ];
    "health", [
      Alcotest.test_case "health check" `Quick test_health_check;
    ];
  ]
