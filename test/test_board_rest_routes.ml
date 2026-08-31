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
