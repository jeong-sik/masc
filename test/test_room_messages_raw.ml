module Types = Masc_domain

open Masc_mcp

let with_test_env f =
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_room_messages_%d_%d" (Unix.getpid ())
       (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Coord.default_config tmp_dir in
  let _ = Coord.init config ~agent_name:(Some "claude") in
  try
    f config;
    let _ = Coord.reset config in
    Unix.rmdir tmp_dir
  with e ->
    let _ = Coord.reset config in
    Unix.rmdir tmp_dir;
    raise e

let test_get_messages_raw_limit_and_order () =
  with_test_env (fun config ->
    let _ = Coord.broadcast config ~from_agent:"claude" ~content:"Message 1" in
    let _ = Coord.broadcast config ~from_agent:"claude" ~content:"Message 2" in
    let _ = Coord.broadcast config ~from_agent:"claude" ~content:"Message 3" in
    let msgs = Coord.get_messages_raw config ~since_seq:0 ~limit:2 in
    let contents = List.map (fun (msg : Masc_domain.message) -> msg.content) msgs in
    Alcotest.(check int) "limit respected" 2 (List.length msgs);
    Alcotest.(check (list string)) "newest messages first"
      ["Message 3"; "Message 2"] contents
  )

let test_get_messages_raw_since_seq_stops_early () =
  with_test_env (fun config ->
    let _ = Coord.broadcast config ~from_agent:"claude" ~content:"Message 1" in
    let _ = Coord.broadcast config ~from_agent:"claude" ~content:"Message 2" in
    let _ = Coord.broadcast config ~from_agent:"claude" ~content:"Message 3" in
    let baseline = Coord.get_messages_raw config ~since_seq:0 ~limit:10 in
    let cutoff_seq =
      match baseline with
      | _latest :: second :: _ -> second.seq
      | _ -> Alcotest.fail "expected at least two messages in baseline"
    in
    let msgs = Coord.get_messages_raw config ~since_seq:cutoff_seq ~limit:10 in
    let contents = List.map (fun (msg : Masc_domain.message) -> msg.content) msgs in
    Alcotest.(check (list string)) "only newer than since_seq"
      ["Message 3"] contents
  )

let test_get_messages_raw_large_history_keeps_newest_window () =
  with_test_env (fun config ->
    for i = 1 to 20 do
      let _ =
        Coord.broadcast config ~from_agent:"claude"
          ~content:(Printf.sprintf "Message %d" i)
      in
      ()
    done;
    let msgs = Coord.get_messages_raw config ~since_seq:5 ~limit:3 in
    let contents = List.map (fun (msg : Masc_domain.message) -> msg.content) msgs in
    Alcotest.(check (list string)) "large history keeps newest 3"
      [ "Message 20"; "Message 19"; "Message 18" ] contents
  )

let () =
  Alcotest.run "Coord raw message regression" [
    ("messages_raw", [
      Alcotest.test_case "limit and newest-first ordering" `Quick
        test_get_messages_raw_limit_and_order;
      Alcotest.test_case "since_seq filters older history" `Quick
        test_get_messages_raw_since_seq_stops_early;
      Alcotest.test_case "large history keeps newest window" `Quick
        test_get_messages_raw_large_history_keeps_newest_window;
    ]);
  ]
