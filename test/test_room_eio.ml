(** Tests for Coord_eio: OCaml 5.x Eio-native Coord implementation *)

(* Initialize RNG before any crypto operations *)
let () = Mirage_crypto_rng_unix.use_default ()

(** Recursive directory cleanup *)
let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
;;

(** Generate unique test directory - deterministic using PID + timestamp *)
let make_test_dir () =
  let unique_id =
    Printf.sprintf
      "masc_room_eio_test_%d_%d"
      (Unix.getpid ())
      (int_of_float (Unix.gettimeofday () *. 1000000.))
  in
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ()) unique_id in
  (try Unix.mkdir tmp_dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  tmp_dir
;;

(** Run test with Eio environment *)
let with_eio_env f =
  Eio_main.run
  @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let tmp_dir = make_test_dir () in
  let config = Coord_eio.test_config ~fs tmp_dir in
  Fun.protect
    ~finally:(fun () ->
      try rm_rf tmp_dir with
      | _ -> ())
    (fun () -> f config)
;;

(** {1 Agent Tests} *)

let test_register_agent () =
  with_eio_env
  @@ fun config ->
  match Coord_eio.register_agent config ~name:"claude" () with
  | Ok agent ->
    Alcotest.(check string) "agent name" "claude" agent.name;
    Alcotest.(check string) "agent status" "active" agent.status
  | Error e -> Alcotest.failf "register_agent failed: %s" e
;;

let test_get_agent () =
  with_eio_env
  @@ fun config ->
  (* Register first *)
  let _ =
    Coord_eio.register_agent config ~name:"gemini" ~capabilities:[ "code"; "review" ] ()
  in
  (* Get agent *)
  match Coord_eio.get_agent config ~name:"gemini" with
  | Ok agent ->
    Alcotest.(check string) "agent name" "gemini" agent.name;
    Alcotest.(check (list string)) "capabilities" [ "code"; "review" ] agent.capabilities
  | Error e -> Alcotest.failf "get_agent failed: %s" e
;;

let test_remove_agent () =
  with_eio_env
  @@ fun config ->
  (* Register *)
  let _ = Coord_eio.register_agent config ~name:"codex" () in
  (* Remove *)
  (match Coord_eio.remove_agent config ~name:"codex" with
   | Ok () -> ()
   | Error e -> Alcotest.failf "remove_agent failed: %s" e);
  (* Verify removed *)
  match Coord_eio.get_agent config ~name:"codex" with
  | Error _ -> () (* Expected: not found *)
  | Ok _ -> Alcotest.fail "agent should have been removed"
;;

(** {1 Lock Tests} *)

let test_acquire_lock () =
  with_eio_env
  @@ fun config ->
  match Coord_eio.acquire_lock config ~resource:"file.txt" ~owner:"claude" with
  | Ok (Some lock) ->
    Alcotest.(check string) "lock resource" "file.txt" lock.resource;
    Alcotest.(check string) "lock owner" "claude" lock.owner
  | Ok None -> Alcotest.fail "lock should have been acquired"
  | Error e -> Alcotest.failf "acquire_lock failed: %s" e
;;

let test_lock_conflict () =
  with_eio_env
  @@ fun config ->
  (* First agent acquires lock *)
  let _ = Coord_eio.acquire_lock config ~resource:"shared.txt" ~owner:"claude" in
  (* Second agent tries to acquire same lock *)
  match Coord_eio.acquire_lock config ~resource:"shared.txt" ~owner:"gemini" with
  | Ok None -> () (* Expected: lock held by claude *)
  | Ok (Some _) -> Alcotest.fail "second agent should not get lock"
  | Error e -> Alcotest.failf "unexpected error: %s" e
;;

let test_release_lock () =
  with_eio_env
  @@ fun config ->
  (* Acquire *)
  let _ = Coord_eio.acquire_lock config ~resource:"temp.txt" ~owner:"claude" in
  (* Release *)
  (match Coord_eio.release_lock config ~resource:"temp.txt" ~owner:"claude" with
   | Ok () -> ()
   | Error e -> Alcotest.failf "release_lock failed: %s" e);
  (* Now another agent can acquire *)
  match Coord_eio.acquire_lock config ~resource:"temp.txt" ~owner:"gemini" with
  | Ok (Some _) -> () (* Expected: lock now available *)
  | Ok None -> Alcotest.fail "lock should be available after release"
  | Error e -> Alcotest.failf "acquire after release failed: %s" e
;;

(** {1 Message Tests} *)

let test_broadcast_message () =
  with_eio_env
  @@ fun config ->
  match Coord_eio.broadcast config ~from_agent:"claude" ~content:"Hello world!" with
  | Ok msg ->
    Alcotest.(check bool) "seq > 0" true (msg.seq > 0);
    Alcotest.(check string) "from_agent" "claude" msg.from_agent;
    Alcotest.(check string) "content" "Hello world!" msg.content
  | Error e -> Alcotest.failf "broadcast failed: %s" e
;;

let test_mention_extraction () =
  with_eio_env
  @@ fun config ->
  match
    Coord_eio.broadcast config ~from_agent:"claude" ~content:"@gemini please review"
  with
  | Ok msg ->
    Alcotest.(check (option string)) "mention extracted" (Some "gemini") msg.mention
  | Error e -> Alcotest.failf "broadcast failed: %s" e
;;

let test_get_message () =
  with_eio_env
  @@ fun config ->
  (* Broadcast first *)
  let msg_result =
    Coord_eio.broadcast config ~from_agent:"claude" ~content:"Test message"
  in
  match msg_result with
  | Error e -> Alcotest.failf "broadcast failed: %s" e
  | Ok msg ->
    (* Get the message *)
    (match Coord_eio.get_message config ~seq:msg.seq with
     | Ok retrieved ->
       Alcotest.(check string) "content matches" "Test message" retrieved.content
     | Error e -> Alcotest.failf "get_message failed: %s" e)
;;

(** {1 State Tests} *)

let test_room_state () =
  with_eio_env
  @@ fun config ->
  (* Register some agents *)
  let _ = Coord_eio.register_agent config ~name:"claude" () in
  let _ = Coord_eio.register_agent config ~name:"gemini" () in
  (* Read state *)
  match Coord_eio.read_state config with
  | Ok state ->
    Alcotest.(check bool) "has agents" true (List.length state.active_agents >= 2);
    Alcotest.(check bool) "not paused" false state.paused
  | Error e -> Alcotest.failf "read_state failed: %s" e
;;

let test_room_status () =
  with_eio_env
  @@ fun config ->
  let _ = Coord_eio.register_agent config ~name:"claude" () in
  let status = Coord_eio.status config in
  let open Yojson.Safe.Util in
  Alcotest.(check bool)
    "has protocol_version"
    true
    (status |> member "protocol_version" |> to_string <> "")
;;

(** {1 Health Check Tests} *)

let test_health_check () =
  with_eio_env
  @@ fun config ->
  match Coord_eio.health_check config with
  | Ok result -> Alcotest.(check bool) "is healthy" true result.is_healthy
  | Error e -> Alcotest.failf "health_check failed: %s" e
;;

let () =
  Alcotest.run
    "Coord_eio"
    [ ( "agent"
      , [ Alcotest.test_case "register agent" `Quick test_register_agent
        ; Alcotest.test_case "get agent" `Quick test_get_agent
        ; Alcotest.test_case "remove agent" `Quick test_remove_agent
        ] )
    ; ( "lock"
      , [ Alcotest.test_case "acquire lock" `Quick test_acquire_lock
        ; Alcotest.test_case "lock conflict" `Quick test_lock_conflict
        ; Alcotest.test_case "release lock" `Quick test_release_lock
        ] )
    ; ( "message"
      , [ Alcotest.test_case "broadcast message" `Quick test_broadcast_message
        ; Alcotest.test_case "mention extraction" `Quick test_mention_extraction
        ; Alcotest.test_case "get message" `Quick test_get_message
        ] )
    ; ( "state"
      , [ Alcotest.test_case "room state" `Quick test_room_state
        ; Alcotest.test_case "room status" `Quick test_room_status
        ] )
    ; "health", [ Alcotest.test_case "health check" `Quick test_health_check ]
    ]
;;
