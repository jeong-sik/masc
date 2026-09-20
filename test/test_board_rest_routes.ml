(** Regression guard for the dashboard board REST bridge (task-1647).

    The dashboard board API client (dashboard/src/api/board.ts) posts to
    [/api/v1/tools/masc_board_*] endpoints. Each MCP board tool the dashboard
    calls needs a matching REST route registered by
    {!Server_routes_http_routes_activity.add_routes}; a missing route makes the
    corresponding dashboard button return 404.

    [masc_board_comment_vote] existed as an MCP tool and was called by the
    comment up/down buttons, but had no REST route — every comment vote
    returned 404. This test builds the real router and asserts that every
    board tool the dashboard depends on resolves to a POST route.

    All [/api/v1/tools/*] routes are registered by this one module, so
    enumerating its [add_routes] output is exhaustive for this route family.
    The expected set mirrors the [/api/v1/tools/*] literals in
    dashboard/src/api/board.ts; adding a dashboard board endpoint requires both
    a new route and an entry here, so drift fails the build. *)

open Alcotest

module Http = Masc.Http_server_eio

let () = Mirage_crypto_rng_unix.use_default ()

let with_reaction_auth_base f =
  let base_path = Filename.temp_dir "board-reaction-auth-" "" in
  Auth.save_auth_config
    base_path
    { Masc_domain.default_auth_config with enabled = true; require_token = true };
  f base_path

let reaction_auth_request ?token () =
  let headers =
    match token with
    | None -> Httpun.Headers.of_list []
    | Some token ->
      Httpun.Headers.of_list [ "authorization", "Bearer " ^ token ]
  in
  Httpun.Request.create ~headers `GET "/api/v1/board/reactions"

let reaction_internal_auth_request token =
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list [ "x-masc-internal-token", token ])
    `GET
    "/api/v1/board/reactions"

let reaction_raw_auth_request header value =
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list [ header, value ])
    `GET
    "/api/v1/board/reactions"

(* /api/v1/tools/* endpoints called by dashboard/src/api/board.ts, plus the
   goal lifecycle and schedule write routes the TUI consumes. Kept in sync
   with those consumers — see module doc. *)
let dashboard_board_tool_routes =
  [ "/api/v1/tools/masc_board_vote"
  ; "/api/v1/tools/masc_board_post"
  ; "/api/v1/tools/masc_board_comment"
  ; "/api/v1/tools/masc_board_comment_vote"
  ; "/api/v1/tools/masc_goal_transition"
  ; "/api/v1/tools/masc_schedule_create"
  ; "/api/v1/tools/masc_schedule_update"
  ; "/api/v1/tools/masc_schedule_cancel"
  ]

let dashboard_board_reaction_routes =
  [ `GET, "/api/v1/board/reactions/catalog"
  ; `GET, "/api/v1/board/reactions"
  ; `POST, "/api/v1/board/reactions"
  ]

(* [add_routes] only registers closures — no fiber is spawned — so the
   [Eio_main.run] just supplies the switch + clock the handlers capture. *)
let with_router f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      let router =
        Server_routes_http_routes_activity.add_routes
          ~sw
          ~clock
          (Http.Router.create ())
      in
      f router))

(* Every dashboard-consumed board tool must resolve to a Plain POST route. *)
let test_dashboard_board_routes_registered () =
  with_router (fun router ->
    List.iter
      (fun path ->
        let request = Httpun.Request.create `POST path in
        match Http.Router.resolve router request with
        | `Matched route -> (
          match route.Http.Router.handler with
          | Http.Router.Plain _ -> ()
          | Http.Router.Ws _ ->
            fail (Printf.sprintf "%s must be a Plain POST route, not Ws" path))
        | `Method_not_allowed ->
          fail (Printf.sprintf "%s exists but rejects POST" path)
        | `Not_found ->
          fail
            (Printf.sprintf
               "%s is not registered — dashboard call would 404"
               path))
      dashboard_board_tool_routes)

(* The registered /api/v1/tools/* set must equal the dashboard-consumed set:
   no orphan server route, no dashboard endpoint left unregistered. *)
let test_no_tools_route_drift () =
  with_router (fun router ->
    let registered =
      Http.Router.routes router
      |> List.filter_map (fun (r : Http.Router.route) ->
             if String.starts_with ~prefix:"/api/v1/tools/" r.Http.Router.path
             then Some r.Http.Router.path
             else None)
      |> List.sort_uniq String.compare
    in
    let expected = List.sort_uniq String.compare dashboard_board_tool_routes in
    check
      (list string)
      "registered /api/v1/tools/* routes match dashboard-consumed set"
      expected
      registered)

let test_schedule_write_actor_is_stamped_from_auth () =
  let open Yojson.Safe.Util in
  let stamped =
    Server_routes_http_routes_activity.schedule_stamp_operator_actor
      ~agent_name:"tui-operator"
      (`Assoc
        [ "scheduled_by_id", `String "spoofed"
        ; "requested_by_kind", `String "system"
        ; "message", `String "keep me"
        ])
  in
  check string "scheduled actor" "tui-operator"
    (stamped |> member "scheduled_by_id" |> to_string);
  check string "requested actor" "tui-operator"
    (stamped |> member "requested_by_id" |> to_string);
  check string "scheduled kind" "human_operator"
    (stamped |> member "scheduled_by_kind" |> to_string);
  check string "requested kind" "human_operator"
    (stamped |> member "requested_by_kind" |> to_string);
  check string "form fields survive" "keep me"
    (stamped |> member "message" |> to_string)
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter
      (fun name -> remove_tree (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"
;;

let dispatch_json ?token ~router ~path ~extra_headers ~body () =
  Server_request_authority.with_current
    (loopback_request_authority ())
    (fun () ->
       let output = Buffer.create 1024 in
       let connection =
         Httpun.Server_connection.create (fun reqd ->
           Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
       in
       let extra_headers =
         extra_headers
         |> List.map (fun (name, value) -> name ^ ": " ^ value ^ "\r\n")
         |> String.concat ""
       in
       let authorization =
         Option.fold
           ~none:""
           ~some:(fun token -> "Authorization: Bearer " ^ token ^ "\r\n")
           token
       in
       let raw_request =
         Printf.sprintf
           "POST %s HTTP/1.1\r\n\
            Host: 127.0.0.1:8935\r\n\
            Origin: http://127.0.0.1:8935\r\n\
            %s%s\
            Content-Type: application/json\r\n\
            Content-Length: %d\r\n\
            \r\n\
           %s"
           path
           authorization
           extra_headers
           (String.length body)
           body
       in
       let input =
         Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request
       in
       ignore
         (Httpun.Server_connection.read_eof connection input ~off:0
            ~len:(Bigstringaf.length input));
       let rec drain () =
         match Httpun.Server_connection.next_write_operation connection with
         | `Write iovecs ->
           let bytes =
             List.fold_left
               (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
                  Buffer.add_string output
                    (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
                  total + iov.len)
               0
               iovecs
           in
           Httpun.Server_connection.report_write_result connection (`Ok bytes);
           drain ()
         | `Yield | `Close _ -> ()
       in
       drain ();
       let raw = Buffer.contents output in
       let status =
         int_of_string (List.nth (String.split_on_char ' ' raw) 1)
       in
       let rec body_offset index =
         if index + 4 > String.length raw then fail ("no HTTP body: " ^ raw)
         else if String.sub raw index 4 = "\r\n\r\n" then index + 4
         else body_offset (index + 1)
       in
       let offset = body_offset 0 in
       ( status
       , Yojson.Safe.from_string
           (String.sub raw offset (String.length raw - offset)) ))
;;

let with_authenticated_activity_router ~prefix ~agent_name f =
  let base_path = Filename.temp_dir prefix "" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      remove_tree base_path)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       Eio.Switch.run
       @@ fun sw ->
       let state = Masc.Mcp_server.For_testing.create_state ~base_path in
       let config = Masc.Mcp_server.workspace_config state in
       ignore (Masc.Workspace.init config ~agent_name:(Some "test"));
       Server_auth.For_testing.restore_server_state (Some state);
       Auth.save_auth_config base_path
         { Masc_domain.default_auth_config with
           enabled = true
         ; require_token = true
         };
       let token =
         match
           Auth.create_token base_path ~agent_name
             ~role:Masc_domain.Admin
       with
         | Ok (token, _) -> token
         | Error error -> fail (Masc_domain.masc_error_to_string error)
       in
       let clock = Eio.Stdenv.clock env in
       let router =
         Server_routes_http_routes_activity.add_routes
           ~sw
           ~clock
           (Http.Router.create ())
       in
       f ~base_path ~config ~router ~token)
;;

let test_schedule_cancel_actor_is_stamped_from_auth () =
  with_authenticated_activity_router
    ~prefix:"schedule-cancel-http-actor-"
    ~agent_name:"credential-owner"
  @@ fun ~base_path:_ ~config ~router ~token ->
  let actor : Schedule_domain.actor =
    { id = "test"
    ; kind = Schedule_domain.Human_operator
    ; display_name = None
    }
  in
  let schedule =
    match
      Schedule_service.create config ~now:100.0 ~schedule_id:"sched-http-auth"
        ~requested_at:100.0 ~requested_by:actor ~scheduled_by:actor
        ~due_at:200.0
        ~payload:
          (`Assoc
             [ "kind", `String "consumer.note"
             ; "body", `Assoc [ "text", `String "cancel me" ]
             ])
        ~source:Schedule_domain.Operator_request ()
    with
    | Ok schedule -> schedule
    | Error error -> fail (Schedule_service.service_error_to_string error)
  in
  let body =
    `Assoc
      [ "schedule_id", `String schedule.schedule_id
      ; "cancelled_by_id", `String "forged-body-actor"
      ; "cancelled_by_kind", `String "system"
      ; "reason", `String "duplicate"
      ]
    |> Yojson.Safe.to_string
  in
  let status, response =
    dispatch_json ~router ~token
      ~path:"/api/v1/tools/masc_schedule_cancel"
      ~extra_headers:[ "X-Masc-Agent", "forged-header-actor" ] ~body ()
  in
       let open Yojson.Safe.Util in
       check int "cancel accepted" 200 status;
       check string "credential owner is the canceller" "credential-owner"
         (response |> member "data" |> member "cancelled_by" |> member "id"
          |> to_string);
       check string "terminal bridge uses typed human operator" "human_operator"
    (response |> member "data" |> member "cancelled_by" |> member "kind"
     |> to_string)
;;

let board_post_by_title title =
  Masc.Board_dispatch.list_posts ~sort_by:Masc.Board_dispatch.Recent ~limit:20 ()
  |> List.find_opt (fun (post : Masc.Board.post) -> String.equal post.title title)
;;

let test_board_write_routes_use_authenticated_actor () =
  with_authenticated_activity_router
    ~prefix:"board-write-http-actor-"
    ~agent_name:"credential-owner"
  @@ fun ~base_path ~config:_ ~router ~token ->
  Fun.protect
    ~finally:Masc.Board.reset_global_for_test
  @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path)
  @@ fun () ->
  Fun.protect ~finally:Masc.Board_dispatch.reset_for_test
  @@ fun () ->
  Masc.Board.reset_global_for_test ();
  Masc.Board_dispatch.reset_for_test ();
  Masc.Board_dispatch.init_jsonl ();
  let post_json path fields =
    dispatch_json ~router ~token ~path
      ~extra_headers:[ "X-Masc-Agent", "forged-header-actor" ]
      ~body:(Yojson.Safe.to_string (`Assoc fields)) ()
  in
  let status, _ =
    post_json "/api/v1/tools/masc_board_post"
      [ "title", `String "canonical actor route test"
      ; "body", `String "the bearer owner writes this post"
      ; "author", `String "forged-body-actor"
      ]
  in
  check int "post accepted" 201 status;
  let post =
    match board_post_by_title "canonical actor route test" with
    | Some post -> post
    | None -> fail "board route did not create the post"
  in
  let post_id = Masc.Board.Post_id.to_string post.id in
  check string "post author" "credential-owner"
    (Masc.Board.Agent_id.to_string post.author);
  let status, _ =
    post_json "/api/v1/tools/masc_board_comment"
      [ "post_id", `String post_id
      ; "content", `String "canonical actor route comment"
      ; "author", `String "forged-body-actor"
      ]
  in
  check int "comment accepted" 201 status;
  let comment =
    match Masc.Board_dispatch.get_comments ~post_id with
    | Ok comments ->
      (match
         List.find_opt
           (fun (comment : Masc.Board.comment) ->
              String.equal comment.content "canonical actor route comment")
           comments
       with
       | Some comment -> comment
       | None -> fail "board route did not create the comment")
    | Error error -> fail (Masc.Board.show_board_error error)
  in
  let comment_id = Masc.Board.Comment_id.to_string comment.id in
  check string "comment author" "credential-owner"
    (Masc.Board.Agent_id.to_string comment.author);
  let status, _ =
    post_json "/api/v1/tools/masc_board_vote"
      [ "post_id", `String post_id
      ; "direction", `String "up"
      ; "voter", `String "forged-body-actor"
      ]
  in
  check int "post vote accepted" 200 status;
  let status, _ =
    post_json "/api/v1/tools/masc_board_comment_vote"
      [ "comment_id", `String comment_id
      ; "direction", `String "down"
      ; "voter", `String "forged-body-actor"
      ]
  in
  check int "comment vote accepted" 200 status;
  (match
     Masc.Board_dispatch.current_vote_for_post ~voter:"credential-owner" ~post_id
   with
   | Ok (Some Masc.Board.Up) -> ()
   | Ok (Some Masc.Board.Down) | Ok None -> fail "canonical post vote was not stored"
   | Error error -> fail (Masc.Board.show_board_error error));
  (match
     Masc.Board_dispatch.current_vote_for_post ~voter:"forged-header-actor" ~post_id
   with
   | Ok None -> ()
   | Ok (Some _) -> fail "forged header actor owns the post vote"
   | Error error -> fail (Masc.Board.show_board_error error));
  (match
     Masc.Board_dispatch.current_vote_for_comment
       ~voter:"credential-owner"
       ~comment_id
   with
   | Ok (Some Masc.Board.Down) -> ()
   | Ok (Some Masc.Board.Up) | Ok None -> fail "canonical comment vote was not stored"
   | Error error -> fail (Masc.Board.show_board_error error));
  (match
     Masc.Board_dispatch.current_vote_for_comment
       ~voter:"forged-header-actor"
       ~comment_id
   with
   | Ok None -> ()
   | Ok (Some _) -> fail "forged header actor owns the comment vote"
   | Error error -> fail (Masc.Board.show_board_error error));
  Auth.save_auth_config base_path
    { Masc_domain.default_auth_config with
      enabled = false
    ; require_token = false
    };
  let status, _ =
    dispatch_json ~router
      ~path:"/api/v1/tools/masc_board_post"
      ~extra_headers:[ "X-Masc-Agent", "local-dashboard-actor" ]
      ~body:
        (Yojson.Safe.to_string
           (`Assoc
              [ "title", `String "tokenless local dashboard actor"
              ; "body", `String "same-origin local attribution remains available"
              ; "author", `String "forged-body-actor"
              ]))
      ()
  in
  check int "tokenless same-origin dashboard post accepted" 201 status;
  let local_post =
    match board_post_by_title "tokenless local dashboard actor" with
    | Some post -> post
    | None -> fail "tokenless dashboard route did not create the post"
  in
  check string "tokenless local actor comes from admitted auth resolver"
    "local-dashboard-actor"
    (Masc.Board.Agent_id.to_string local_post.author)
;;

let test_dashboard_board_reaction_routes_registered () =
  with_router (fun router ->
    List.iter
      (fun (meth, path) ->
         let request = Httpun.Request.create meth path in
         match Http.Router.resolve router request with
         | `Matched { Http.Router.handler = Plain _; _ } -> ()
         | `Matched { Http.Router.handler = Ws _; _ } ->
           fail (Printf.sprintf "%s must be a plain HTTP route" path)
         | `Method_not_allowed ->
           fail (Printf.sprintf "%s rejects its dashboard HTTP method" path)
         | `Not_found ->
           fail (Printf.sprintf "%s is not registered" path))
      dashboard_board_reaction_routes)

let test_board_reaction_catalog_uses_board_ssot () =
  match Server_board_reaction_http.catalog_json () with
  | `Assoc fields ->
    let actual =
      match List.assoc_opt "supported_reaction_emojis" fields with
      | Some (`List values) ->
        List.filter_map (function `String value -> Some value | _ -> None) values
      | Some _ | None -> fail "supported_reaction_emojis must be a JSON array"
    in
    check (list string) "catalog" Masc.Board.board_reaction_emojis actual
  | _ -> fail "reaction catalog must be a JSON object"

(* A board page asks about its rows together. What the answer has to hold is
   one entry per id the caller named, in the order it named them, so a caller
   can line the answer up against its rows without matching on anything. *)
let batch_target_ids json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "targets" fields with
     | Some (`List rows) ->
       List.map
         (function
           | `Assoc row ->
             (match List.assoc_opt "target_id" row with
              | Some (`String id) -> id
              | Some _ | None -> fail "each target must carry a string target_id")
           | _ -> fail "each target must be a JSON object")
         rows
     | Some _ | None -> fail "batch answer must carry a targets array")
  | _ -> fail "batch answer must be a JSON object"

let parsed_targets ids =
  match
    Server_board_reaction_http.targets_of_strings
      ~target_type:(Some "post")
      ~target_ids:(Some ids)
  with
  | Ok targets -> targets
  | Error _ -> fail (Printf.sprintf "targets_of_strings rejected %S" ids)

(* The projection reads the board store, which the parsing above does not: it
   wants an Eio context and a base path of its own. An empty store is enough
   here -- what is under test is that every id asked about comes back, in the
   order asked, whether or not the store had anything for it. *)
let test_board_reaction_batch_answers_every_id_asked_about () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Unix.putenv
    "MASC_BASE_PATH"
    (Filename.concat
       (Filename.get_temp_dir_name ())
       (Printf.sprintf "masc-test-reaction-batch-%06x" (Random.bits ())));
  Masc.Board_dispatch.reset_for_test ();
  Masc.Board_dispatch.init_jsonl ();
  let json =
    Server_board_reaction_http.list_batch_json
      ~actor:"tester"
      (parsed_targets "p-one,p-two,p-three")
  in
  check
    (list string)
    "one entry per id, in the order asked"
    [ "p-one"; "p-two"; "p-three" ]
    (batch_target_ids json);
  match json with
  | `Assoc fields ->
    check
      bool
      "the emoji catalog rides along so a caller needs no second request"
      true
      (List.mem_assoc "supported_reaction_emojis" fields)
  | _ -> fail "batch answer must be a JSON object"

let test_board_reaction_batch_rejects_an_empty_or_oversized_list () =
  let rejected ids =
    match
      Server_board_reaction_http.targets_of_strings
        ~target_type:(Some "post")
        ~target_ids:ids
    with
    | Ok _ -> false
    | Error _ -> true
  in
  check bool "no ids at all" true (rejected (Some ""));
  check bool "only separators" true (rejected (Some " , , "));
  check bool "missing entirely" true (rejected None);
  check
    bool
    "more ids than a page can hold"
    true
    (rejected (Some (String.concat "," (List.init 501 (fun i -> Printf.sprintf "p-%d" i)))));
  check
    bool
    "a full page is answered"
    false
    (rejected (Some (String.concat "," (List.init 500 (fun i -> Printf.sprintf "p-%d" i)))))

let test_board_reaction_batch_rejects_an_unknown_target_type () =
  match
    Server_board_reaction_http.targets_of_strings
      ~target_type:(Some "planet")
      ~target_ids:(Some "p-one")
  with
  | Ok _ -> fail "an unknown target_type must not parse"
  | Error _ -> ()

let test_board_reaction_optional_auth_is_anonymous_only_without_header () =
  with_reaction_auth_base (fun base_path ->
    match
      Server_auth.authorize_optional_token_bound_permission_request
        ~base_path
        ~permission:Masc_domain.CanReadState
        (reaction_auth_request ())
    with
    | Ok None -> ()
    | Ok (Some actor) ->
      failf "headerless request unexpectedly resolved actor %s" actor
    | Error error -> fail (Masc_domain.masc_error_to_string error))

let test_board_reaction_optional_auth_rejects_invalid_header () =
  with_reaction_auth_base (fun base_path ->
    match
      Server_auth.authorize_optional_token_bound_permission_request
        ~base_path
        ~permission:Masc_domain.CanReadState
        (reaction_auth_request ~token:"invalid-board-reaction-token" ())
    with
    | Error error ->
      check bool "invalid credential is unauthorized" true
        (Server_auth.http_status_of_auth_error error = `Unauthorized)
    | Ok None -> fail "invalid Authorization header fell back to anonymous"
    | Ok (Some actor) -> failf "invalid credential resolved actor %s" actor)

let test_board_reaction_optional_auth_rejects_invalid_internal_header () =
  with_reaction_auth_base (fun base_path ->
    match
      Server_auth.authorize_optional_token_bound_permission_request
        ~base_path
        ~permission:Masc_domain.CanReadState
        (reaction_internal_auth_request "invalid-internal-token")
    with
    | Error error ->
      check bool "invalid internal credential is unauthorized" true
        (Server_auth.http_status_of_auth_error error = `Unauthorized)
    | Ok None -> fail "invalid internal bearer fell back to anonymous"
    | Ok (Some actor) -> failf "invalid internal bearer resolved actor %s" actor)

let test_board_reaction_optional_auth_rejects_malformed_credentials () =
  with_reaction_auth_base (fun base_path ->
    List.iter
      (fun (label, request) ->
         check bool
           (label ^ " is detected as a credential")
           true
           (Server_auth.request_carries_auth_credential request);
         match
           Server_auth.authorize_optional_token_bound_permission_request
             ~base_path
             ~permission:Masc_domain.CanReadState
             request
         with
         | Error error ->
           check bool
             (label ^ " is unauthorized")
             true
             (Server_auth.http_status_of_auth_error error = `Unauthorized)
         | Ok None -> failf "%s fell back to anonymous" label
         | Ok (Some actor) -> failf "%s resolved actor %s" label actor)
      [ ( "malformed Authorization"
        , reaction_raw_auth_request "authorization" "Basic not-a-bearer" )
      ; ( "empty internal credential"
        , reaction_raw_auth_request "x-masc-internal-token" " " )
      ])

let test_dashboard_dev_token_can_vote_as_credential_owner () =
  with_reaction_auth_base (fun base_path ->
    match
      Server_routes_http_dashboard_dev_token.ensure_dashboard_dev_token base_path
    with
    | Error error ->
      fail
        (Server_routes_http_dashboard_dev_token.token_error_to_string error)
    | Ok token ->
      match
        Server_auth.authorize_token_bound_permission_request
          ~base_path
          ~permission:Masc_domain.CanVote
          (reaction_auth_request ~token:token.raw ())
      with
      | Ok actor -> check string "dashboard credential owner" "dashboard" actor
      | Error error -> fail (Masc_domain.masc_error_to_string error))

let () =
  run
    "board_rest_routes"
    [ ( "dashboard bridge"
      , [ test_case
            "dashboard board tool routes registered"
            `Quick
            test_dashboard_board_routes_registered
        ; test_case
            "no /api/v1/tools/* route drift"
            `Quick
            test_no_tools_route_drift
        ; test_case "schedule write actor comes from auth" `Quick
            test_schedule_write_actor_is_stamped_from_auth
        ; test_case "schedule cancel actor comes from auth" `Quick
            test_schedule_cancel_actor_is_stamped_from_auth
        ; test_case "board write actors come from auth" `Quick
            test_board_write_routes_use_authenticated_actor
        ; test_case
            "dashboard board reaction routes registered"
            `Quick
            test_dashboard_board_reaction_routes_registered
        ; test_case
            "reaction catalog uses Board SSOT"
            `Quick
            test_board_reaction_catalog_uses_board_ssot
        ; test_case
            "optional reaction auth is anonymous only without header"
            `Quick
            test_board_reaction_optional_auth_is_anonymous_only_without_header
        ; test_case
            "optional reaction auth rejects invalid header"
            `Quick
            test_board_reaction_optional_auth_rejects_invalid_header
        ; test_case
            "optional reaction auth rejects invalid internal header"
            `Quick
            test_board_reaction_optional_auth_rejects_invalid_internal_header
        ; test_case
            "optional reaction auth rejects malformed credentials"
            `Quick
            test_board_reaction_optional_auth_rejects_malformed_credentials
        ; test_case
            "dashboard dev-token can vote as credential owner"
            `Quick
            test_dashboard_dev_token_can_vote_as_credential_owner
        ; test_case
            "reaction batch answers every id asked about"
            `Quick
            test_board_reaction_batch_answers_every_id_asked_about
        ; test_case
            "reaction batch rejects an empty or oversized list"
            `Quick
            test_board_reaction_batch_rejects_an_empty_or_oversized_list
        ; test_case
            "reaction batch rejects an unknown target type"
            `Quick
            test_board_reaction_batch_rejects_an_unknown_target_type
        ] )
    ]
