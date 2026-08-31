open Alcotest
open Masc

module Router = Masc.Http_server_eio.Router

let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

let test_dir () =
  let path = Filename.temp_file "masc-fusion-run-detail" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path
;;

let rec cleanup_dir path =
  if Sys.file_exists path
  then if Sys.is_directory path
  then (
    Sys.readdir path
    |> Array.iter (fun name -> cleanup_dir (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path
;;

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some value -> Unix.putenv key value
      | None -> Unix.putenv key "")
    f
;;

let read_source path =
  let root = Sys.getenv_opt "DUNE_SOURCEROOT" |> Option.value ~default:"." in
  let channel = open_in_bin (Filename.concat root path) in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let contains text needle = String_util.contains_substring text needle
let json = testable Yojson.Safe.pp Yojson.Safe.equal

let test_h1_and_h2_routes_are_registered () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let routes =
    Server_routes_http_routes_dashboard.add_routes
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      (Router.create ())
  in
  let request = Httpun.Request.create `GET "/api/v1/dashboard/fusion-runs/run-123" in
  (match Router.resolve routes request with
   | `Matched route ->
     check string
       "H1 fusion detail prefix"
       "/api/v1/dashboard/fusion-runs/"
       route.path
   | `Method_not_allowed -> fail "H1 fusion detail GET was method-not-allowed"
   | `Not_found -> fail "H1 fusion detail GET route was not registered");
  let h2 = read_source "lib/server/server_h2_gateway.ml" in
  check bool
    "H2 exact list uses public-read wrapper"
    true
    (contains h2
       "| `GET, \"/api/v1/dashboard/fusion-runs\" ->\n          with_h2_public_read h2_reqd");
  check bool
    "H2 detail uses the shared prefix"
    true
    (contains h2 "Server_dashboard_fusion_run_projection.detail_prefix");
  check bool
    "H2 list uses the shared builder"
    true
    (contains h2 "Server_dashboard_fusion_run_projection.list_response");
  check bool
    "H2 detail uses the shared builder"
    true
    (contains h2 "Server_dashboard_fusion_run_projection.detail_response")
;;

let test_list_and_unknown_detail_responses () =
  let registry = Fusion_run_registry.create () in
  Fusion_run_registry.register_running
    registry
    ~run_id:"fusion-list-run"
    ~keeper:"fusion-detail-keeper"
    ~preset:"test"
    ~topology:Fusion_types.Simple
    ~started_at:1.0;
  let list_json =
    Server_routes_http_routes_dashboard.For_testing.fusion_run_list_response
      ~registry
  in
  check int "list count" 1 Yojson.Safe.Util.(list_json |> member "count" |> to_int);
  check string
    "list run id"
    "fusion-list-run"
    Yojson.Safe.Util.(list_json |> member "runs" |> index 0 |> member "run_id" |> to_string);
  check string
    "new run exposes accepted stage"
    "accepted"
    Yojson.Safe.Util.(list_json |> member "runs" |> index 0 |> member "stage" |> to_string);
  check json
    "accepted stage has an explicit empty progress object"
    (`Assoc [])
    Yojson.Safe.Util.(list_json |> member "runs" |> index 0 |> member "progress");
  Fusion_run_registry.mark_progress registry ~run_id:"fusion-list-run"
    ~progress:
      (Fusion_run_registry.Progress_judge_running
         { expected = 3; answered = 2; failed = 1 });
  let progressing_json =
    Server_routes_http_routes_dashboard.For_testing.fusion_run_list_response
      ~registry
  in
  let progressing = Yojson.Safe.Util.(progressing_json |> member "runs" |> index 0) in
  check string "list exposes live judge stage" "judge"
    Yojson.Safe.Util.(progressing |> member "stage" |> to_string);
  check int "list exposes answered count" 2
    Yojson.Safe.Util.(progressing |> member "progress" |> member "panel_answered" |> to_int);
  let status, json =
    Server_routes_http_routes_dashboard.For_testing.fusion_run_detail_response
      ~registry
      ~path:"/api/v1/dashboard/fusion-runs/unknown-fusion-run"
  in
  check bool "unknown detail is 404" true (status = `Not_found);
  check string
    "unknown run is named"
    "no retained fusion run named unknown-fusion-run"
    Yojson.Safe.Util.(json |> member "error" |> to_string)
;;

let with_board f =
  let base_path = test_dir () in
  Fun.protect
    ~finally:(fun () ->
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      cleanup_dir base_path)
    (fun () ->
       with_env "MASC_BASE_PATH" base_path (fun () ->
         Eio_main.run @@ fun env ->
         Fs_compat.set_fs (Eio.Stdenv.fs env);
         Board.reset_global_for_test ();
         Board_dispatch.reset_for_test ();
         Board_dispatch.init_jsonl ();
         f ()))
;;

let test_detail_uses_exact_typed_board_origin () =
  with_board @@ fun () ->
  let registry = Fusion_run_registry.create () in
  let pending_run_id = "fusion-detail-pending" in
  Fusion_run_registry.register_running
    registry
    ~run_id:pending_run_id
    ~keeper:"fusion-detail-keeper"
    ~preset:"test"
    ~topology:Fusion_types.Simple
    ~started_at:10.0;
  (match
     Board_dispatch.create_post
       ~author:"fusion-detail-test"
       ~content:("mentions " ^ pending_run_id)
       ~post_kind:Board.System_post
       ~meta_json:(`Assoc [ "fusion_run_id", `String pending_run_id ])
       ()
   with
   | Ok _ -> ()
   | Error error -> fail (Board.show_board_error error));
  let wrong_source_origin : Board.post_origin =
    { turn_ref = None
    ; source = Some "not-fusion"
    ; fusion_run_id = Some pending_run_id
    }
  in
  (match
     Board_dispatch.create_post
       ~author:"fusion-detail-test"
       ~content:"typed run id with the wrong source"
       ~post_kind:Board.System_post
       ~origin:wrong_source_origin
       ()
   with
   | Ok _ -> ()
   | Error error -> fail (Board.show_board_error error));
  let pending_status, pending_json =
    Server_routes_http_routes_dashboard.For_testing.fusion_run_detail_response
      ~registry
      ~path:("/api/v1/dashboard/fusion-runs/" ^ pending_run_id)
  in
  check bool "known running run is 200" true (pending_status = `OK);
  let pending_evidence = Yojson.Safe.Util.member "evidence" pending_json in
  check string
    "text, meta, and a non-fusion origin do not count as evidence"
    "pending"
    Yojson.Safe.Util.(pending_evidence |> member "status" |> to_string);
  check bool
    "pending post is explicit null"
    true
    (Yojson.Safe.Util.member "post" pending_evidence = `Null);
  Fusion_run_registry.mark_completed
    registry
    ~run_id:pending_run_id
    ~outcome:Fusion_run_registry.Succeeded;
  let completed_status, completed_json =
    Server_routes_http_routes_dashboard.For_testing.fusion_run_detail_response
      ~registry
      ~path:("/api/v1/dashboard/fusion-runs/" ^ pending_run_id)
  in
  check bool "known completed run is 200" true (completed_status = `OK);
  let completed_evidence = Yojson.Safe.Util.member "evidence" completed_json in
  check string
    "completed run without exact post is absent"
    "absent"
    Yojson.Safe.Util.(completed_evidence |> member "status" |> to_string);
  check bool
    "absent post is explicit null"
    true
    (Yojson.Safe.Util.member "post" completed_evidence = `Null);
  let recorded_run_id = "fusion-detail-recorded" in
  Fusion_run_registry.register_running
    registry
    ~run_id:recorded_run_id
    ~keeper:"fusion-detail-keeper"
    ~preset:"test"
    ~topology:Fusion_types.Simple
    ~started_at:20.0;
  let origin : Board.post_origin =
    { turn_ref = None
    ; source = Some "fusion"
    ; fusion_run_id = Some recorded_run_id
    }
  in
  let panel_meta =
    `List
      [ `Assoc
          [ "model", `String "first"
          ; "status", `String "answered"
          ; "answer", `String "answer-sentinel"
          ]
      ; `Assoc
          [ "model", `String "second"
          ; "status", `String "failed"
          ; "reason_code", `String "timeout"
          ; "reason_detail", `String "failure-sentinel"
          ]
      ]
  in
  let post =
    match
      Board_dispatch.create_post
        ~author:"fusion-detail-test"
        ~content:"exact typed origin evidence"
        ~post_kind:Board.System_post
        ~meta_json:(`Assoc [ "panel", panel_meta ])
        ~origin
        ()
    with
    | Ok post -> post
    | Error error -> fail (Board.show_board_error error)
  in
  Fusion_run_registry.mark_completed
    registry
    ~run_id:recorded_run_id
    ~outcome:
      (Fusion_run_registry.Succeeded_with_summary
         { decision = "answer"; summary = "answer-sentinel" });
  let recorded_status, recorded_json =
    Server_routes_http_routes_dashboard.For_testing.fusion_run_detail_response
      ~registry
      ~path:("/api/v1/dashboard/fusion-runs/" ^ recorded_run_id)
  in
  check bool "recorded run is 200" true (recorded_status = `OK);
  let recorded_evidence = Yojson.Safe.Util.member "evidence" recorded_json in
  check string
    "exact origin is recorded"
    "recorded"
    Yojson.Safe.Util.(recorded_evidence |> member "status" |> to_string);
  let post_json = Yojson.Safe.Util.member "post" recorded_evidence in
  check string
    "exact indexed post is returned"
    (Board.Post_id.to_string post.id)
    Yojson.Safe.Util.(post_json |> member "id" |> to_string);
  check string "completed decision is projected" "answer"
    Yojson.Safe.Util.(recorded_json |> member "run" |> member "decision" |> to_string);
  check string "completed summary is projected" "answer-sentinel"
    Yojson.Safe.Util.(recorded_json |> member "run" |> member "summary" |> to_string);
  check string
    "returned post keeps typed run origin"
    recorded_run_id
    Yojson.Safe.Util.(post_json |> member "origin" |> member "fusion_run_id" |> to_string);
  check json
    "panel evidence keeps source order and failure fields"
    panel_meta
    Yojson.Safe.Util.(post_json |> member "meta" |> member "panel")
;;

let () =
  run
    "dashboard fusion run projection"
    [ ( "routes"
      , [ test_case "H1 and H2 routes are registered" `Quick
            test_h1_and_h2_routes_are_registered
        ] )
    ; ( "responses"
      , [ test_case "list and unknown detail responses" `Quick
            test_list_and_unknown_detail_responses
        ; test_case "detail uses exact typed Board origin" `Quick
            test_detail_uses_exact_typed_board_origin
        ] )
    ]
;;
