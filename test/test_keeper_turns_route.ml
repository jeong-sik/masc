open Masc

(* GET /api/v1/keepers/turns is what the TUI "answering now" badge polls:
   the running-turn slot lives in the Keeper Owner (process memory), so the
   durable meta the TUI's keeper list is read from cannot answer it.

   The listing exposes current Keeper Owner state. *)

(* Drive the handler the way an HTTP server would: hand its request to a
   Server_connection and collect the response bytes it writes. The write
   result is reported for the full iovec length, not 0 bytes — reporting
   zero would stall the connection's writer and hang the test. *)
let request_response ~handle ~request =
  let output = Buffer.create 512 in
  let connection =
    Httpun.Server_connection.create (fun reqd ->
        handle (Httpun.Reqd.request reqd) reqd)
  in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
  ignore
    (Httpun.Server_connection.read_eof connection input ~off:0
       ~len:(Bigstringaf.length input));
  let rec drain () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let written =
        List.fold_left
          (fun acc (iov : Bigstringaf.t Httpun.IOVec.t) ->
             Buffer.add_string output
               (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
             acc + iov.len)
          0 iovecs
      in
      Httpun.Server_connection.report_write_result connection (`Ok written);
      drain ()
    | `Yield | `Close _ -> ()
  in
  drain ();
  Buffer.contents output
;;

let turns_response ~state =
  request_response ~handle:(Server_routes_http_keeper_stream.handle_keeper_turns_list state)
    ~request:"GET /api/v1/keepers/turns HTTP/1.1\r\nHost: x\r\n\r\n"
;;

let post_response ~handle body =
  request_response ~handle
    ~request:(Printf.sprintf "POST / HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
      (String.length body) body)
;;

let body_of response =
  match Str.bounded_split (Str.regexp "\r\n\r\n") response 2 with
  | [ _; body ] -> body
  | _ -> Alcotest.failf "no body separator in response: %S" response
;;

(* Decode the existing server fixture's actual wire with the HTTP client parser,
   including framing and headers. No socket or custom response parser. *)
let client_response request wire =
  let client = Httpun.Client_connection.create () in
  let result = ref None in
  let writer = Httpun.Client_connection.request client request
      ~error_handler:(fun _ -> Alcotest.fail "unexpected client response error")
      ~response_handler:(fun response reader ->
        let body = Buffer.create 512 in
        let rec consume () = Httpun.Body.Reader.schedule_read reader
            ~on_eof:(fun () -> result := Some
              { Masc_http_client.status=Httpun.Status.to_code response.status
              ; headers=Httpun.Headers.to_list response.headers; body=Buffer.contents body })
            ~on_read:(fun chunk ~off ~len ->
              Buffer.add_string body (Bigstringaf.substring chunk ~off ~len);
              consume ()) in
        consume ()) in
  Httpun.Body.Writer.close writer;
  let rec drain_request () =
    match Httpun.Client_connection.next_write_operation client with
    | `Write iovecs ->
        let written = List.fold_left (fun n (iov : Bigstringaf.t Httpun.IOVec.t) -> n+iov.len) 0 iovecs in
        Httpun.Client_connection.report_write_result client (`Ok written);
        drain_request ()
    | `Yield | `Close _ -> () in
  drain_request ();
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length wire) wire in
  (match Httpun.Client_connection.next_read_operation client with
   | `Read -> ignore (Httpun.Client_connection.read_eof client input ~off:0 ~len:(Bigstringaf.length input))
   | `Yield | `Close -> Alcotest.fail "HTTP client cannot read its response");
  match !result with Some response -> response | None -> Alcotest.fail "incomplete HTTP response"
;;

let with_test_state f =
  let dir = Filename.temp_file "keeper-turns" ".dir" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace_utils.default_config dir in
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
    (fun () ->
      let request_authority =
        match
          Server_request_authority.of_host_port ~host:"localhost" ~port:8935
        with
        | Ok authority -> authority
        | Error `Malformed -> Alcotest.fail "test authority must be valid"
      in
      Server_request_authority.with_current request_authority (fun () ->
          ignore (Workspace.init config ~agent_name:None);
          let state = Mcp_server_eio.For_testing.create_state ~base_path:dir () in
          f ~sw ~config ~state))
;;

let member key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let test_empty_workspace_answers_an_empty_fleet () =
  with_test_state (fun ~sw:_ ~config:_ ~state ->
      let body = body_of (turns_response ~state) in
      let json = Yojson.Safe.from_string body in
      (match member "schema" json with
       | Some (`String "masc.keeper_turns.v1") -> ()
       | other ->
         Alcotest.failf "unexpected schema field: %s"
           (match other with
            | Some value -> Yojson.Safe.to_string value
            | None -> "absent"));
      match member "keepers" json with
      | Some (`List []) -> ()
      | Some (`List rows) ->
        Alcotest.failf "expected no rows, got %d" (List.length rows)
      | _ -> Alcotest.fail "keepers field absent or mistyped")
;;

let test_installed_keeper_rides_as_an_idle_row () =
  with_test_state (fun ~sw ~config ~state ->
      let keeper_name = "turns-route-keeper" in
      let meta =
        match
          Masc_test_deps.meta_of_json_fixture
            (`Assoc
              [ ("name", `String keeper_name)
              ; ("trace_id", `String "trace-keeper-turns-route")
              ; ("activation_mode", `String "manual")
              ])
        with
        | Ok meta -> meta
        | Error err -> Alcotest.fail err
      in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error err -> Alcotest.failf "persist keeper meta: %s" err);
      (match
         Keeper_owner_registry.install_from_store
           ~sw
           ~operation_runner:None
           ~on_turn_slot_released:None
           config
       with
       | Ok count -> Alcotest.(check int) "installed owner count" 1 count
       | Error error ->
         Alcotest.fail (Keeper_owner_registry.install_error_to_string error));
      let body = body_of (turns_response ~state) in
      let json = Yojson.Safe.from_string body in
      match member "keepers" json with
      | Some (`List [ row ]) ->
        (match member "keeper_name" row with
         | Some (`String name) ->
           Alcotest.(check string) "row names the keeper" keeper_name name
         | _ -> Alcotest.fail "row carries no keeper_name");
        (match member "status" row with
         | Some (`String "ok") -> ()
         | other ->
           Alcotest.failf "expected ok status, got %s"
             (match other with
              | Some value -> Yojson.Safe.to_string value
              | None -> "absent"));
        (match member "turn" row with
         | Some `Null -> ()
         | Some value ->
           Alcotest.failf "expected no running turn, got %s"
             (Yojson.Safe.to_string value)
         | None -> Alcotest.fail "row carries no turn field")
      | Some (`List rows) ->
        Alcotest.failf "expected one row, got %d" (List.length rows)
      | _ -> Alcotest.fail "keepers field absent or mistyped")
;;

let test_interrupt_rejects_invalid_or_conflicting_identity () =
  with_test_state (fun ~sw:_ ~config:_ ~state ->
    List.iter (fun body ->
      let response = post_response
        ~handle:(Server_routes_http_keeper_stream.handle_keeper_turn_interrupt ~actor:"turns-route-test" state) body in
      Alcotest.(check bool) "bad identity is rejected before any cancellation" true
        (String_util.contains_substring response "400 Bad Request"))
      [ "{"; {|{"name":"alpha","interrupt_token":null}|}
      ; {|{"name":"alpha","interrupt_token":""}|}
      ; {|{"name":"alpha","interrupt_token":4}|}
      ; {|{"name":"alpha","request_id":"operation-1","interrupt_token":"bd985f83-b447-45ee-a638-2e2a71f4e144"}|} ])
;;

let test_owned_turn_survives_bound_read_refusal_and_recovery () =
  with_test_state (fun ~sw ~config ~state ->
    let name = "workspace-bound-turn" in
    let install config trace_id =
      let meta = match Masc_test_deps.meta_of_json_fixture (`Assoc
        ["name",`String name;"trace_id",`String trace_id;"activation_mode",`String "manual"]) with
        | Ok value -> value | Error detail -> Alcotest.fail detail in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> () | Error detail -> Alcotest.fail detail);
      (match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None
          ~on_turn_slot_released:None config with
       | Ok _ -> () | Error error -> Alcotest.fail (Keeper_owner_registry.install_error_to_string error));
      match Keeper_owner_registry.get ~base_path:config.base_path ~keeper_name:name with
      | Ok owner -> owner | Error error -> Alcotest.fail (Keeper_owner_registry.lookup_error_to_string error) in
    let owner = install config "original-owner" in
    let foreign_base = Filename.concat config.base_path "foreign-workspace" in
    Unix.mkdir foreign_base 0o700;
    let foreign = Workspace_utils.default_config foreign_base in
    ignore (Workspace.init foreign ~agent_name:None);
    let foreign_state = Mcp_server_eio.For_testing.create_state ~base_path:foreign_base () in
    ignore (install foreign "foreign-idle-owner");
    let original = Ids.Turn_ref.make ~trace_id:"actual-original-turn" ~absolute_turn:7 in
    let entered, enter = Eio.Promise.create () in
    let release, allow_release = Eio.Promise.create () in
    let finished, finish = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      let outcome = Keeper_owner.run_maintenance_if_idle owner (fun () ->
        let writer = Some (Keeper_turn_preview.reset ~keeper_name:name
          ~execution_scope:None ~turn_ref:(Some original) ~now:0.
          ~redaction:Keeper_secret_redaction.empty) in
        Keeper_turn_preview.with_preparation ~writer ~turn_ref:(Some original)
          ~phase:Keeper_turn_preview.World_preparation (fun () ->
            Eio.Promise.resolve enter ();
            Eio.Promise.await release)) in
      Eio.Promise.resolve finish outcome);
    Eio.Promise.await entered;
    let slot = match Keeper_owner.turn_in_flight owner with
      | Some slot -> slot | None -> Alcotest.fail "original Owner did not hold its turn" in
    let expected : Tui_decode.server_identity =
      { sid_version="0.24.0"; sid_binary_commit="owned-turn-source"; sid_binary_commit_age_s=None
      ; sid_base_path=Tui_decode.Canonical_path.of_path (Unix.realpath config.base_path);
        sid_masc_root=Tui_decode.Canonical_path.of_path (Unix.realpath (Workspace.masc_dir config))
      ; sid_executable_in_worktree=None; sid_state_ready=Some true
      ; sid_uptime=None; sid_sse_clients=None; sid_gc=None; sid_scheduler=None } in
    let served = ref state in
    let host = "localhost" and port = 8935 in
    let kept_reads = Masc_tui_kept_reads.create () in
    let send ~path ~headers =
      let headers = ("host", "localhost:8935")::headers in
      let request = Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET path in
      let raw = Printf.sprintf "GET %s HTTP/1.1\r\n%s\r\n" path
          (String.concat "" (List.map (fun (key,value) -> key ^ ": " ^ value ^ "\r\n") headers)) in
      let wire = request_response ~request:raw ~handle:(fun request reqd ->
        Server_auth.with_read_workspace_precondition !served
          Server_routes_http_keeper_stream.handle_keeper_turns_list request reqd) in
      Ok (client_response request wire) in
    let poll () =
      let reply, complete = Eio.Promise.create () in
      Masc_tui_async_read.launch ~source:Masc_tui_async_read.Keeper_turns
        ~deliver:(Eio.Promise.resolve complete) (fun () ->
          Masc_tui_workspace_read.with_binding ~host ~port ~expected
            ~proof:Masc_tui_workspace_read.Request_precondition (fun () ->
              let ( let* ) = Result.bind in
              let* json = Masc_tui_workspace_read.read_json ~kept_reads
                  ~address_of:(fun ~path -> Printf.sprintf "http://%s:%d%s" host port path)
                  ~send ~decode:Tui_decode.decode_json_response_body ~host ~port
                  ~path:("/api/v1/keepers/turns?preparation_details_for=" ^ name) in
              Tui_decode.decode_keeper_turns json));
      Eio.Promise.await reply in
    let expect_original = function
      | Error detail -> Alcotest.fail detail
      | Ok rows ->
          let row = List.find (fun (row : Tui_decode.keeper_turn_row) -> row.ktr_keeper_name=name) rows in
          Alcotest.(check (option string)) "original chat control observation" (Some (Keeper_owner.chat_control_token owner))
            row.ktr_chat_control_token;
          (match row.ktr_state with
           | Tui_decode.Keeper_turn_running {interrupt_token;preview=Some preview;_} ->
               Alcotest.(check string) "actual original slot token"
                 (Keeper_interrupt_token.to_string slot.interrupt_token) interrupt_token;
               Alcotest.(check bool) "actual original preparation lineage" true
                 (match preview.ktp_preparation with
                  | Some preparation -> preparation.turn_ref=Some original
                      && preparation.phase=Keeper_turn_preview.World_preparation
                      && preparation.state=Keeper_turn_preview.Preparation_active
                  | None -> false)
           | Keeper_turn_running _ | Keeper_turn_idle | Keeper_turn_unavailable _ ->
               Alcotest.fail "admitted Owner turn lost original running/preparation state") in
    expect_original (poll ());
    served := foreign_state;
    (match poll () with Error _ -> () | Ok _ -> Alcotest.fail "foreign idle row replaced the original running observation");
    Alcotest.(check bool) "read refusal does not mutate the original turn" true
      (match Keeper_owner.turn_in_flight owner with
       | Some current -> Keeper_interrupt_token.equal current.interrupt_token slot.interrupt_token
       | None -> false);
    served := state;
    expect_original (poll ());
    Eio.Promise.resolve allow_release ();
    (match Eio.Promise.await finished with
     | Ok (`Ran ()) -> ()
     | Ok (`Busy _) -> Alcotest.fail "original maintenance lost its slot"
     | Error error -> Alcotest.fail (Keeper_owner.error_to_string error));
    (match poll () with
     | Ok rows -> Alcotest.(check bool) "actual finished Owner becomes idle only after completion" true
         (List.exists (fun (row : Tui_decode.keeper_turn_row) -> row.ktr_keeper_name=name
           && row.ktr_state=Tui_decode.Keeper_turn_idle) rows)
     | Error detail -> Alcotest.fail detail))
;;

let test_run_next_ownership_and_started_boundary () =
  with_test_state (fun ~sw ~config ~state ->
    let name = "priority-route" in
    let meta = match Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name",`String name;"trace_id",`String "trace-priority-route";"activation_mode",`String "manual"]) with
      | Ok meta -> meta | Error detail -> Alcotest.fail detail in
    (match Keeper_meta_store.replace_snapshot config meta with Ok () -> () | Error e -> Alcotest.fail e);
    (match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
     | Ok _ -> () | Error e -> Alcotest.fail (Keeper_owner_registry.install_error_to_string e));
    let operation_id raw = match Keeper_chat_operation.Operation_id.of_string raw with
      | Ok id -> id | Error e -> Alcotest.fail e in
    let submit actor raw =
      let source = `Assoc
        ["schema",`String "masc.keeper_chat_operation.source.v2";"submitted_by",`String actor
        ;"thread_id",`String ("keeper:" ^ name)
        ;"continuation_channel",`Assoc ["kind",`String "dashboard";"thread_id",`String ("keeper:" ^ name)]
        ;"surface",`Assoc ["kind",`String "dashboard"]
        ;"channel",`String "";"channel_user_id",`String "";"channel_user_name",`String "";"channel_workspace_id",`String ""
        ;"conversation_id",`Null;"external_message_id",`Null;"workspace_id",`Null;"extra_mentions",`List []
        ;"sender_keeper",`Null;"user_row_origin",`String "needs_append"] in
      let input = Keeper_chat_operation_payload.input_to_json ~message:raw ~user_blocks:[]
        ~turn_instructions:None ~surface_context:None ~attachments:[] in
      match Keeper_owner_registry.submit_operation ~base_path:config.base_path ~keeper_name:name
        ~operation_id:(operation_id raw) ~source ~input with
      | Ok _ -> () | Error e -> Alcotest.fail (Keeper_owner_registry.command_error_to_string e) in
    submit "other-keeper" "other-first";
    submit "masc-tui" "mine";
    let owner = match Keeper_owner_registry.get ~base_path:config.base_path ~keeper_name:name with
      | Ok owner -> owner | Error e -> Alcotest.fail (Keeper_owner_registry.lookup_error_to_string e) in
    let order () = match Keeper_owner.list_queued_operations owner ~after_sequence:None ~limit:10 with
      | Ok rows -> List.map (fun (row:Keeper_chat_operation.t) -> Keeper_chat_operation.Operation_id.to_string row.operation_id) rows
      | Error e -> Alcotest.fail (Keeper_owner.error_to_string e) in
    let request ?predecessors id = Yojson.Safe.to_string (`Assoc
      (["name",`String name;"request_id",`String id;"interrupt_token",`Null]
       @ match predecessors with
         | None -> []
         | Some ids -> ["priority_predecessors",`List (List.map (fun id -> `String id) ids)])) in
    let post ?predecessors id = post_response
      ~handle:(Server_routes_http_keeper_stream.handle_keeper_run_next state ~actor:"masc-tui")
      (request ?predecessors id) in
    Alcotest.(check bool) "other producer is forbidden" true (String_util.contains_substring (post "other-first") "403 Forbidden");
    Alcotest.(check (list string)) "forbidden action changes nothing" ["other-first";"mine"] (order ());
    Alcotest.(check bool) "own queued input is prioritized" true (String_util.contains_substring (post "mine") "200 OK");
    Alcotest.(check (list string)) "only own input moves" ["mine";"other-first"] (order ());
    ignore (post "mine");
    Alcotest.(check (list string)) "replayed command has no duplicate" ["mine";"other-first"] (order ());
    (match Keeper_owner.claim_next_operation owner with Ok (Some _) -> () | _ -> Alcotest.fail "claim failed");
    (* Claiming the promoted [mine] leaves [other-first] queued. It must
       survive both the rejected predecessor and the later FIFO cohort. *)
    Alcotest.(check bool) "running input is not replayed or interrupted" true
      (String_util.contains_substring (post "mine") "409 Conflict");
    submit "other-keeper" "outsider";
    List.iter (submit "masc-tui") ["mine-a"; "mine-b"; "mine-c"];
    Alcotest.(check bool) "foreign predecessor is rejected" true
      (String_util.contains_substring
         (post ~predecessors:["outsider"] "mine-b") "409 Conflict");
    Alcotest.(check (list string)) "foreign predecessor changes no order"
      ["other-first";"outsider";"mine-a";"mine-b";"mine-c"] (order ());
    Alcotest.(check bool) "first automatic priority accepted" true
      (String_util.contains_substring (post ~predecessors:[] "mine-a") "200 OK");
    Alcotest.(check bool) "second automatic priority accepted" true
      (String_util.contains_substring
         (post ~predecessors:["mine-a"] "mine-b") "200 OK");
    Alcotest.(check bool) "third automatic priority accepted" true
      (String_util.contains_substring
         (post ~predecessors:["mine-a";"mine-b"] "mine-c") "200 OK");
    Alcotest.(check (list string)) "HTTP automatic priority persists accepted FIFO"
      ["mine-a";"mine-b";"mine-c";"other-first";"outsider"] (order ()))
;;

let () =
  Alcotest.run "keeper_turns_route"
    [ ( "keeper-turns-route"
      , [ Alcotest.test_case "invalid or conflicting interrupt identity" `Quick test_interrupt_rejects_invalid_or_conflicting_identity
        ; Alcotest.test_case "original turn through workspace refusal and recovery" `Quick test_owned_turn_survives_bound_read_refusal_and_recovery
        ; Alcotest.test_case "run-next ownership, idempotency, and started boundary" `Quick test_run_next_ownership_and_started_boundary

        ; Alcotest.test_case "empty workspace answers an empty fleet" `Quick
            test_empty_workspace_answers_an_empty_fleet
        ; Alcotest.test_case "an installed keeper rides as an idle row" `Quick
            test_installed_keeper_rides_as_an_idle_row
        ] )
    ]
;;
