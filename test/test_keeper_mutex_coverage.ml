open Alcotest
open Masc_mcp

let wait_for_done request_id =
  let rec loop remaining =
    match Keeper_msg_async.poll request_id with
    | Some ({ status = Done _; _ } as entry) -> entry
    | _ when remaining <= 0 ->
      failwith (Printf.sprintf "request %s did not complete" request_id)
    | _ ->
      Eio.Fiber.yield ();
      loop (remaining - 1)
  in
  loop 200
;;

let with_eio_env f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.clear_fs ();
      Eio_guard.disable ())
    (fun () -> f env)
;;

let test_keeper_msg_async_roundtrip () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let request_id =
    Keeper_msg_async.submit ~sw ~keeper_name:"alpha" ~f:(fun () ->
      Eio.Fiber.yield ();
      true, Yojson.Safe.to_string (`Assoc [ "kind", `String "done" ]))
  in
  let entry = wait_for_done request_id in
  Alcotest.(check bool)
    "request completed"
    true
    (match entry.Keeper_msg_async.status with
     | Done { ok = true; body } -> String.length body > 0
     | _ -> false);
  Alcotest.(check int)
    "one pending entry"
    1
    (List.length (Keeper_msg_async.list_for_keeper ~keeper_name:"alpha"))
;;

let () =
  run
    "keeper_mutex_coverage"
    [ ( "keeper_msg_async"
      , [ test_case "submit/poll roundtrip" `Quick test_keeper_msg_async_roundtrip ] )
    ]
;;
