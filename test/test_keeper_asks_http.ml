open Alcotest
open Masc

let wire_response ~router target =
  let output = Buffer.create 4096 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd) in
  let raw = Printf.sprintf "GET %s HTTP/1.1\r\nHost: localhost:8935\r\n\r\n" target in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw) raw in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
  let rec drain () = match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let written = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
        total+iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result connection (`Ok written);
      drain ()
    | `Yield | `Close _ -> () in
  drain ();
  let raw = Buffer.contents output in
  let boundary = Str.search_forward (Str.regexp_string "\r\n\r\n") raw 0 in
  let status = int_of_string (List.nth (String.split_on_char ' ' raw) 1) in
  status, Yojson.Safe.from_string (String.sub raw (boundary+4) (String.length raw-boundary-4))

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
        ~continuation:(Keeper_continuation_channel.unrouted "workspace-bound read fixture") ~asked_at:42. ()
        |> valid Keeper_ask.invalid_ask_to_string in
      Keeper_ask_store.record_ask ~base_path:config.base_path ask |> valid Fun.id;
      let router = Http_server_eio.Router.create ()
        |> Http_server_eio.Router.get "/api/v1/keepers/asks"
             (Server_routes_http_keeper_stream.handle_keeper_asks_list state) in
      let base = Unix.realpath config.base_path and root = Unix.realpath (Workspace.masc_dir config) in
      let encode = Uri.pct_encode ~component:`Query_value in
      let query = "expected_base_path=" ^ encode base ^ "&expected_masc_root=" ^ encode root in
      let path = "/api/v1/keepers/asks" in
      List.iter (fun suffix ->
        let status,body = wire_response ~router (path ^ suffix) in
        check int "bound named and fleet reads succeed" 200 status;
        let snapshot = Tui_decode_asks.decode_asks_snapshot ~expected_base_path:base ~expected_masc_root:root body
          |> valid Fun.id in
        match snapshot.asn_rows with
        | [row] ->
          check string "original ask survives the wire" ask.ask_id row.ar_id;
          check string "original Keeper survives the wire" name row.ar_keeper;
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
