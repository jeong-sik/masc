open Masc_mcp

let test_dir () =
  let tmp = Filename.temp_file "masc_room_messages_pg" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some prev -> Unix.putenv key prev
      | None -> Unix.putenv key "")
    f

let with_pg_test_env f =
  match Sys.getenv_opt "MASC_POSTGRES_URL" with
  | None | Some "" -> ()
  | Some url ->
      let dir = test_dir () in
      Fun.protect
        ~finally:(fun () -> cleanup_dir dir)
        (fun () ->
          with_env "MASC_STORAGE_TYPE" "postgres" @@ fun () ->
          with_env "MASC_POSTGRES_URL" url @@ fun () ->
          with_env "DATABASE_URL" "" @@ fun () ->
          with_env "SUPABASE_DB_URL" "" @@ fun () ->
          with_env "SB_PG_URL" "" @@ fun () ->
          Eio_main.run @@ fun env ->
          Eio.Switch.run @@ fun sw ->
          let config =
            Room_utils.default_config_eio ~sw ~env:(env :> Caqti_eio.stdenv) dir
          in
          match config.Room_utils.backend with
          | Room_utils.PostgresNative _ ->
              let _ = Room.init config ~agent_name:(Some "claude") in
              Fun.protect
                ~finally:(fun () -> ignore (Room.reset config))
                (fun () -> f ~env ~sw ~config)
          | Room_utils.Memory _ | Room_utils.FileSystem _ -> ())

let test_get_messages_raw_uses_postgres_backend () =
  with_pg_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let _ = Room.broadcast config ~from_agent:"claude" ~content:"Message 1" in
  let _ = Room.broadcast config ~from_agent:"claude" ~content:"Message 2" in
  let _ = Room.broadcast config ~from_agent:"claude" ~content:"Message 3" in
  let msgs = Room.get_messages_raw config ~since_seq:0 ~limit:2 in
  let contents = List.map (fun (msg : Types.message) -> msg.content) msgs in
  Alcotest.(check int) "limit respected" 2 (List.length msgs);
  Alcotest.(check (list string)) "newest messages first from postgres"
    [ "Message 3"; "Message 2" ] contents

let () =
  Alcotest.run "Room PG message regression"
    [
      ( "messages_pg",
        [
          Alcotest.test_case "get_messages_raw uses postgres backend" `Quick
            test_get_messages_raw_uses_postgres_backend;
        ] );
    ]
