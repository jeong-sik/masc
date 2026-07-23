open Alcotest
open Masc

let temp_dir () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_board_inference_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end
      else Sys.remove path
  in
  rm dir

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:(Some "keeper-sangsu-agent"));
      f config)

let make_meta name : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
          ("trace_id", `String ("trace-" ^ name));
          ("autoboot_enabled", `Bool false);
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let post_id_of_string s =
  match Board.Post_id.of_string s with
  | Ok id -> id
  | Error _ -> Alcotest.failf "failed to parse post_id %S" s

let agent_id_of_string s =
  match Board.Agent_id.of_string s with
  | Ok id -> id
  | Error _ -> Alcotest.failf "failed to parse agent_id %S" s

let make_post ~id ~author =
  { Board.id = post_id_of_string id;
    author = agent_id_of_string author;
    title = "Test post";
    body = "Test body";
    content = "Test content";
    post_kind = Board.Human_post;
    meta_json = None;
    visibility = Board.Internal;
    created_at = Unix.gettimeofday ();
    updated_at = Unix.gettimeofday ();
    expires_at = Unix.gettimeofday () +. 3600.0;
    votes_up = 0;
    votes_down = 0;
    reply_count = 0;
    pinned = false;
    hearth = None;
    thread_id = None;
    origin = None;
  }

let check_bad_request label expected = function
  | Error (`Bad_request msg) -> check string label expected msg
  | Error (`Internal_server_error msg) ->
    fail (Printf.sprintf "expected Bad_request, got Internal_server_error: %s" msg)
  | Ok _ -> fail "expected Bad_request error"

let test_parse_request () =
  (* 1. Valid payload *)
  let json = `Assoc [("post_id", `String "post-123"); ("target_keeper", `String "sangsu")] in
  (match Server_routes_http_routes_activity.parse_board_context_inference_request json with
   | Ok req ->
     check string "post_id parsed" "post-123" req.post_id;
     check (option string) "target_keeper parsed" (Some "sangsu") req.target_keeper
   | Error err -> fail ("parse failed: " ^ err));

  (* 2. Missing post_id *)
  let json = `Assoc [("target_keeper", `String "sangsu")] in
  (match Server_routes_http_routes_activity.parse_board_context_inference_request json with
   | Error err -> check string "error on missing post_id" "post_id is required" err
   | Ok _ -> fail "expected parsing error");

  (* 3. Whitespace target_keeper *)
  let json = `Assoc [("post_id", `String "post-123"); ("target_keeper", `String "  ")] in
  (match Server_routes_http_routes_activity.parse_board_context_inference_request json with
   | Ok req ->
     check string "post_id parsed" "post-123" req.post_id;
     check (option string) "target_keeper parsed as None" None req.target_keeper
   | Error err -> fail ("parse failed: " ^ err))

let test_target_resolution_explicit_registered () =
  with_workspace (fun config ->
    (* Register keeper "sangsu" *)
    (match Keeper_meta_store.write_meta config (make_meta "sangsu") with
     | Ok _ -> ()
     | Error msg -> fail ("write_meta failed: " ^ msg));

    let post = make_post ~id:"post-1" ~author:"operator" in
    match Server_routes_http_routes_activity.resolve_board_context_inference_target ~config post (Some "sangsu") with
    | Ok (resolved_name, source) ->
      check string "resolved name" "sangsu" resolved_name;
      check bool "source is Explicit_target" true (source = Server_routes_http_routes_activity.Explicit_target)
    | Error _ -> fail "expected resolution to succeed")

let test_target_resolution_explicit_unregistered () =
  with_workspace (fun config ->
    let post = make_post ~id:"post-1" ~author:"operator" in
    Server_routes_http_routes_activity.resolve_board_context_inference_target
      ~config post (Some "chulsoo")
    |> check_bad_request
         "error message"
         "target_keeper \"chulsoo\" is not a registered keeper")

let test_target_resolution_implicit_registered_author () =
  with_workspace (fun config ->
    (* Register keeper "sangsu" *)
    (match Keeper_meta_store.write_meta config (make_meta "sangsu") with
     | Ok _ -> ()
     | Error msg -> fail ("write_meta failed: " ^ msg));

    (* Post author matches a registered keeper (either by short name or full agent name) *)
    let post = make_post ~id:"post-1" ~author:"sangsu" in
    match Server_routes_http_routes_activity.resolve_board_context_inference_target ~config post None with
    | Ok (resolved_name, source) ->
      check string "resolved name" "sangsu" resolved_name;
      check bool "source is Post_author" true (source = Server_routes_http_routes_activity.Post_author)
    | Error _ -> fail "expected resolution to succeed")

let test_target_resolution_implicit_unregistered_author () =
  with_workspace (fun config ->
    (* Post author is "operator", which is not a registered keeper *)
    let post = make_post ~id:"post-1" ~author:"operator" in
    Server_routes_http_routes_activity.resolve_board_context_inference_target
      ~config post None
    |> check_bad_request
         "error message"
         "target_keeper is required because board post author \"operator\" is not a registered keeper")

let () =
  run "Server board context inference resolution"
    [ ( "parse_request",
        [ test_case "parse request payloads" `Quick test_parse_request ] )
    ; ( "target_resolution",
        [ test_case "explicit registered target" `Quick test_target_resolution_explicit_registered
        ; test_case "explicit unregistered target" `Quick test_target_resolution_explicit_unregistered
        ; test_case "implicit registered author" `Quick test_target_resolution_implicit_registered_author
        ; test_case "implicit unregistered author" `Quick test_target_resolution_implicit_unregistered_author
        ] )
    ]
