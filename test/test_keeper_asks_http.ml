open Alcotest
open Masc

let wire_raw_response ?(meth=`GET) ?(body="") ?(http_version="HTTP/1.1") ~router target =
  let output = Buffer.create 4096 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd) in
  let raw = Printf.sprintf "%s %s %s\r\nHost: localhost:8935\r\nContent-Length: %d\r\n\r\n%s"
      (Httpun.Method.to_string meth) target http_version (String.length body) body in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw) raw in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
  let rec drain () = match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let written = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
        total+iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result connection (`Ok written);
      drain ()
    | `Yield when Buffer.length output=0 ->
      let ready,resolve = Eio.Promise.create () in
      Httpun.Server_connection.yield_writer connection (fun () -> Eio.Promise.resolve resolve ());
      Eio.Promise.await ready;
      drain ()
    | `Yield | `Close _ -> () in
  drain ();
  let raw = Buffer.contents output in
  let boundary = Str.search_forward (Str.regexp_string "\r\n\r\n") raw 0 in
  let status = int_of_string (List.nth (String.split_on_char ' ' raw) 1) in
  status, String.sub raw (boundary+4) (String.length raw-boundary-4)

let wire_response ?meth ?body ~router target =
  let status,body = wire_raw_response ?meth ?body ~router target in
  status,Yojson.Safe.from_string body

let test_original_questions_are_bound_to_receiving_workspace () =
  let dir = Filename.temp_file "masc-asks-http-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let prior_startup = Server_startup_state.snapshot () in
  Fun.protect ~finally:(fun () ->
    Server_startup_state.For_testing.restore prior_startup;
    Masc_test_deps.cleanup_test_workspace dir) (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Switch.run @@ fun sw ->
    Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw (fun () ->
    let state = Mcp_server.For_testing.create_state ~base_path:dir in
    let config = Mcp_server.workspace_config state in
    ignore (Workspace.init config ~agent_name:None);
    (match Server_startup_state.mark_state_ready () with
     | Ok () -> () | Error error -> fail (Server_startup_state.state_ready_error_to_string error));
    let name = "original-asker" in
    let meta = match Masc_test_deps.meta_of_json_fixture
        (`Assoc ["name",`String name;"trace_id",`String "original-ask-trace"]) with
      | Ok value -> value | Error detail -> fail detail in
    let entry = Keeper_registry.register_offline ~base_path:config.base_path name meta in
    Fun.protect ~finally:(fun () -> ignore (Keeper_registry.unregister_exact entry)) (fun () ->
      let valid render = function Ok value -> value | Error error -> fail (render error) in
      let choice = Keeper_ask.choice ~choice_id:"later" ~label:"After lunch" ()
        |> valid Keeper_ask.invalid_choice_to_string in
      let question = Keeper_ask.question ~question_id:"window" ~header:"Window" ~prompt:"When?"
        ~mode:Keeper_ask.Single ~free_text:Keeper_ask.Choices_only ~choices:[choice]
        |> valid Keeper_ask.invalid_question_to_string in
      let ask = Keeper_ask.ask ~ask_id:"original-ask" ~keeper_name:name ~questions:[question]
        ~source_turn_ref:(Ids.Turn_ref.make ~trace_id:"original-ask-trace" ~absolute_turn:17)
        ~continuation:(Keeper_continuation_channel.unrouted "workspace-bound read fixture") ~asked_at:42. ()
        |> valid Keeper_ask.invalid_ask_to_string in
      Keeper_ask_store.record_ask ~base_path:config.base_path ask |> valid Fun.id;
      let router = Http_server_eio.Router.create ()
        |> Http_server_eio.Router.get "/api/v1/keepers/asks"
             (Server_routes_http_keeper_stream.handle_keeper_asks_list state)
        |> Http_server_eio.Router.post "/api/v1/keepers/ask-answer"
             (Server_routes_http_keeper_stream.handle_keeper_ask_answer ~actor:"operator" state) in
      let base = Unix.realpath config.base_path and root = Unix.realpath (Workspace.masc_dir config) in
      let encode = Uri.pct_encode ~component:`Query_value in
      let query = "expected_base_path=" ^ encode base ^ "&expected_masc_root=" ^ encode root in
      let path = "/api/v1/keepers/asks" in
      List.iter (fun suffix ->
        let status,body = wire_response ~router (path ^ suffix) in
        check int "bound named and fleet reads succeed" 200 status;
        let rows = Yojson.Safe.Util.(body |> member "asks" |> to_list) in
        (match rows with
         | [row] -> check string "HTTP preserves exact original asking execution" "original-ask-trace#17"
             Yojson.Safe.Util.(row |> member "source_turn_ref" |> to_string)
         | _ -> fail "expected original Ask row");
        let snapshot = Tui_decode_asks.decode_asks_snapshot ~expected_base_path:base ~expected_masc_root:root body
          |> valid Fun.id in
        match snapshot.asn_rows with
        | [row] ->
            check (option string) "TUI decodes original source without current Keeper state"
              (Some "original-ask-trace#17") (Option.map Ids.Turn_ref.to_string row.ar_source_turn_ref);
          check string "original ask survives the wire" ask.ask_id row.ar_id;
          check string "original Keeper survives the wire" name (Masc.Tui_decode_asks.ask_asker_label row.ar_asker);
          (match row.ar_questions with
           | [question] -> (match question.aq_choices with
             | [choice] -> check string "answer still names original choice" "later" choice.ac_id
             | _ -> fail "original choice missing")
           | _ -> fail "original question missing")
        | _ -> fail "original open question missing")
        ["?" ^ query; "?name=" ^ name ^ "&" ^ query];
      List.iter (fun (suffix,expected_status) ->
        let status,body = wire_response ~router (path ^ "?name=unregistered&" ^ suffix) in
        check int "workspace precondition precedes Keeper lookup" expected_status status;
        check bool "refusal carries no questions" true (Yojson.Safe.Util.member "asks" body=`Null))
        ["expected_base_path=" ^ encode base,400;
         "expected_masc_root=" ^ encode root,400;
         query ^ "&expected_base_path=" ^ encode base,400;
         query ^ "&expected_masc_root=" ^ encode root,400;
         "expected_base_path=relative&expected_masc_root=" ^ encode root,400;
         "expected_base_path=" ^ encode (base ^ "-other") ^ "&expected_masc_root=" ^ encode root,409;
         "expected_base_path=" ^ encode base ^ "&expected_masc_root=" ^ encode (root ^ "-other"),409];
      let status,body = wire_response ~router path in
      check int "fleet readers can request actual workspace identity" 200 status;
      check bool "unscoped response remains bound to actual roots" true
        (Result.is_ok (Tui_decode_asks.decode_asks_snapshot ~expected_base_path:base ~expected_masc_root:root body));
      ignore (Keeper_registry.unregister_exact entry);
      List.iter (fun suffix ->
        let status,body = wire_response ~router (path ^ suffix) in
        check int "durable questions remain visible without live registration" 200 status;
        let snapshot = Tui_decode_asks.decode_asks_snapshot ~expected_base_path:base ~expected_masc_root:root body
          |> valid Fun.id in
        check int "original open question survives offline state" 1 snapshot.asn_open_count;
        check (list string) "same original question survives" [ask.ask_id]
          (List.map (fun (row : Tui_decode_asks.ask_row) -> row.ar_id) snapshot.asn_rows))
        ["?" ^ query; "?name=" ^ name ^ "&" ^ query];
      let answer ?(choice_id="later") ask_id =
        let body = Yojson.Safe.to_string (`Assoc ["name",`String name;"ask_id",`String ask_id;
          "answers",`List [`Assoc ["question_id",`String "window";"response",
            `Assoc ["kind",`String "chose";"choice_ids",`List [`String choice_id]]]]]) in
        wire_response ~meth:`POST ~body ~router "/api/v1/keepers/ask-answer" in
      let status,_ = answer ~choice_id:"not-an-original-choice" ask.ask_id in
      check int "offline answers still validate the original choice" 400 status;
      let status,body = answer ask.ask_id in
      (match Tui_decode_asks.decode_ask_answer_receipt ~expected_ask_id:ask.ask_id ~status_code:status body with
       | Ok (Tui_decode_asks.Ask_answer_recorded _) -> ()
       | Ok (Ask_answer_already_recorded _ | Ask_answer_written_unconfirmed _ | Ask_answer_refused _)
       | Error _ -> fail "offline original question was not durably answered");
      let followup_path = path ^ "?name=" ^ name ^ "&answer_progress_for=" ^ ask.ask_id ^ "&" ^ query in
      let status,body = wire_response ~router followup_path in
      check int "one exact original answer followup is readable offline" 200 status;
      let observed = Tui_decode_asks.decode_ask_followup ~expected_base_path:base
          ~expected_masc_root:root ~keeper_name:name ~ask_id:ask.ask_id body |> valid Fun.id in
      check bool "queued delivery alone cannot invent turn entry" true
        (match observed.af_reactions with
         | Tui_decode_asks.Ask_reactions_observed {ar_turn_started_at=None;ar_turn_finished_at=None;_} -> true
         | Ask_reactions_observed _ | Ask_reactions_unavailable -> false);
      check bool "HTTP and production decoder preserve absence of original Task binding" true
        (match observed.af_linked_task with Tui_decode_asks.Ask_task_unlinked -> true
         | Ask_task_unavailable _ | Ask_task_missing _ | Ask_task_observed _ -> false);
      (* HTTP/1.0 uses close framing so this in-memory transport can inspect
         SSE payloads without implementing an independent chunk decoder. *)
      let status,body = wire_raw_response ~http_version:"HTTP/1.0" ~router
          (followup_path ^ "&answer_progress_stream=true") in
      check int "exact original followup streams through the real route" 200 status;
      let stream = List.fold_left (fun stream payload ->
          let event = Tui_decode_asks.decode_ask_followup_event ~expected_base_path:base
              ~expected_masc_root:root ~keeper_name:name ~ask_id:ask.ask_id
              (Yojson.Safe.from_string payload) |> valid Fun.id in
          Tui_decode_asks.accept_ask_followup_event stream event |> valid Fun.id)
          Tui_decode_asks.empty_ask_followup_stream (Sse_wire.data_payloads_of_stream body) in
      check bool "HTTP stream completes only after each original source" true
        (Result.is_ok (Tui_decode_asks.finish_ask_followup_stream stream));
      List.iter (fun suffix ->
        let status,_ = wire_response ~router (followup_path ^ suffix) in
        check int "ambiguous stream selection is rejected" 400 status)
        ["&answer_progress_stream=true&answer_progress_stream=true";"&answer_progress_stream=unknown"];
      let status,_ = wire_response ~router (followup_path ^ "&answer_progress_for=another") in
      check int "ambiguous question identity is rejected" 400 status;
      let status,_ = wire_response ~router (path ^ "?answer_progress_for=" ^ ask.ask_id ^ "&" ^ query) in
      check int "followup cannot silently switch to a fleet scan" 400 status;
      let status,body = answer ask.ask_id in
      check int "repeated offline answer retains canonical winner" 409 status;
      (match Tui_decode_asks.decode_ask_answer_receipt ~expected_ask_id:ask.ask_id ~status_code:status body with
       | Ok (Tui_decode_asks.Ask_answer_already_recorded _) -> ()
       | Ok (Ask_answer_recorded _ | Ask_answer_written_unconfirmed _ | Ask_answer_refused _)
       | Error _ -> fail "offline duplicate lost canonical answer receipt");
      let status,_ = answer "unknown-original-ask" in
      check int "offline admission still requires the original recorded ask" 404 status;
      let second_ask = Keeper_ask.ask ~ask_id:"alpha-ask" ~keeper_name:"alpha-asker" ~questions:[question]
        ~source_turn_ref:(Ids.Turn_ref.make ~trace_id:"alpha-ask-trace" ~absolute_turn:3)
        ~continuation:(Keeper_continuation_channel.unrouted "workspace-bound read fixture") ~asked_at:43. ()
        |> valid Keeper_ask.invalid_ask_to_string in
      Keeper_ask_store.record_ask ~base_path:config.base_path second_ask |> valid Fun.id;
      let status,body = wire_response ~router (path ^ "?" ^ query) in
      check int "answered offline fleet remains readable" 200 status;
      check int "open count uses the same canonical answered fold" 1
        (Yojson.Safe.Util.member "open_count" body |> Yojson.Safe.Util.to_int);
      let status,body_all = wire_response ~router (path ^ "?include_resolved=true&" ^ query) in
      check int "fleet with include_resolved is readable" 200 status;
      let fleet_keepers =
        Yojson.Safe.Util.(body_all |> member "asks" |> to_list)
        |> List.map (fun row -> Yojson.Safe.Util.(row |> member "keeper" |> to_string))
      in
      check (list string) "fleet asks are sorted deterministically by keeper_name"
        ["alpha-asker"; name] fleet_keepers;
      Sys.remove (Keeper_ask_store.log_path ~base_path:base ~keeper_name:"alpha-asker");
      let original_log = Keeper_ask_store.log_path ~base_path:base ~keeper_name:name in
      let original_bytes = In_channel.with_open_bin original_log In_channel.input_all in
      let broken = Filename.concat (Filename.dirname original_log) "unreadable.jsonl" in
      Out_channel.with_open_bin broken (fun channel -> output_string channel "{}\n{}\n");
      Unix.chmod broken 0o600;
      let status,body = wire_response ~router (path ^ "?" ^ query) in
      check int "incomplete durable discovery is unavailable" 503 status;
      check bool "incomplete discovery cannot clear questions" true (Yojson.Safe.Util.member "asks" body=`Null);
      check string "503 response names the unreadable log path" broken
        Yojson.Safe.Util.(body |> member "error" |> member "path" |> to_string);
      check bool "503 error message includes the unreadable log path" true
        (String_util.contains_substring
           Yojson.Safe.Util.(body |> member "error" |> member "message" |> to_string)
           broken);
      check string "failed read never rewrites original answer bytes" original_bytes
        (In_channel.with_open_bin original_log In_channel.input_all);
      Sys.remove broken;
      let ready = Server_startup_state.snapshot () in
      Server_startup_state.For_testing.restore {ready with state_ready=false};
      let status,body = wire_response ~router (path ^ "?" ^ query) in
      check int "booting response is still an explicit observation" 200 status;
      check bool "booting observation cannot clear operator questions" true
        (Result.is_error (Tui_decode_asks.decode_asks_snapshot ~expected_base_path:base ~expected_masc_root:root body)))))

let () =
  Mirage_crypto_rng_unix.use_default ();
  Alcotest.run "Keeper Ask HTTP workspace"
    ["wire",[test_case "original questions bind to both workspace roots before lookup" `Quick
      test_original_questions_are_bound_to_receiving_workspace]]
