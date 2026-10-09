open Alcotest
open Masc
module Http = Http_server_eio
module Api = Server_dashboard_http_keeper_native_tasks
module Read = Keeper_native_task_read
let () = Mirage_crypto_rng_unix.use_default ()

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let require_ok error = function Ok value -> value | Error value -> fail (error value)

let http ~router ?token ~meth ~path ?(body = "") () =
  let output = Buffer.create 1024 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd) in
  let authorization = match token with
    | None -> "" | Some token -> "Authorization: Bearer " ^ token ^ "\r\n" in
  let raw_request = Printf.sprintf
    "%s %s HTTP/1.1\r\nHost: x\r\n%sX-Masc-Agent: spoofed-header-actor\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
    meth path authorization (String.length body) body in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
  let rec drain () = match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let bytes = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
        total + iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result connection (`Ok bytes); drain ()
    | `Yield | `Close _ -> () in
  drain ();
  let raw = Buffer.contents output in
  let status = int_of_string (List.nth (String.split_on_char ' ' raw) 1) in
  let rec body_offset index =
    if index + 4 > String.length raw then fail ("no HTTP body: " ^ raw)
    else if String.sub raw index 4 = "\r\n\r\n" then index + 4 else body_offset (index + 1) in
  let offset = body_offset 0 in
  status, Yojson.Safe.from_string (String.sub raw offset (String.length raw - offset))
;;

let wire_response ~handler ~headers target =
  let response = ref None in
  let body = Buffer.create 4096 in
  let complete = ref false in
  let client = H2.Client_connection.create
    ~error_handler:(fun _ -> fail "H2 JSON connection error") () in
  let request = H2.Request.create ~scheme:"http" `GET target
    ~headers:(H2.Headers.of_list ((":authority", "localhost:8935") :: headers)) in
  let writer = H2.Client_connection.request client request
    ~error_handler:(fun _ -> fail "H2 JSON stream error")
    ~response_handler:(fun reply reader ->
      response := Some (H2.Status.to_code reply.H2.Response.status, H2.Headers.to_list reply.headers);
      let rec consume () = H2.Body.Reader.schedule_read reader
        ~on_eof:(fun () -> complete := true)
        ~on_read:(fun buffer ~off ~len ->
          Buffer.add_string body (Bigstringaf.substring buffer ~off ~len);
          consume ()) in
      consume ()) in
  H2.Body.Writer.close writer;
  let server = H2.Server_connection.create handler in
  let transfer next_write report_write read =
    let rec drain progressed = match next_write () with
      | `Write iovecs ->
        let written = List.fold_left (fun total (iov : Bigstringaf.t H2.IOVec.t) ->
          let rec feed off remaining =
            if remaining > 0 then (
              let consumed = read iov.buffer ~off ~len:remaining in
              if consumed <= 0 then fail "H2 JSON transfer made no progress";
              feed (off + consumed) (remaining - consumed))
          in
          feed iov.off iov.len;
          total + iov.len) 0 iovecs in
        report_write (`Ok written);
        drain true
      | `Yield | `Close _ -> progressed
    in
    drain false
  in
  let rec pump () =
    let sent = transfer
      (fun () -> H2.Client_connection.next_write_operation client)
      (H2.Client_connection.report_write_result client) (H2.Server_connection.read server) in
    let received = transfer
      (fun () -> H2.Server_connection.next_write_operation server)
      (H2.Server_connection.report_write_result server) (H2.Client_connection.read client) in
    if !complete then ()
    else if sent || received then pump ()
    else fail "H2 JSON route stalled before response completion"
  in
  pump ();
  match !response with
  | Some (status, headers) -> status, headers, Buffer.contents body
  | None -> fail "H2 JSON route omitted response headers"


let with_fixture f =
  let base_path = Filename.temp_dir "native-task-http" "" in
  let previous = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect ~finally:(fun () ->
    Server_auth.For_testing.restore_server_state previous;
    Fs_compat.clear_fs (); remove_tree base_path) (fun () ->
    Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let state = Mcp_server.For_testing.create_state ~base_path in
    let config = Mcp_server.workspace_config state in
    ignore (Workspace.init config ~agent_name:None);
    Server_auth.For_testing.restore_server_state (Some state);
    Auth.save_auth_config base_path
      {Masc_domain.default_auth_config with enabled=true; require_token=true};
    let token agent_name role = fst (require_ok Masc_domain.masc_error_to_string
      (Auth.create_token base_path ~agent_name ~role)) in
    let admin = token "task-admin" Masc_domain.Admin in
    let worker = token "task-worker" Masc_domain.Worker in
    let router = Server_routes_http_routes_dashboard.add_routes ~sw
      ~clock:(Eio.Stdenv.clock env) (Http.Router.create ()) in
    let trust_policy = require_ok Server_request_authority.trust_policy_error_to_string
      (Server_request_authority.make_trust_policy ~bind_host:"localhost"
        ~bind_port:8935 ~explicit_base_url:None) in
    let handler = Server_h2_gateway.make_request_handler ~trust_policy ~sw ~request_sw:sw
      ~clock:(Eio.Stdenv.clock env) ~server_start_time:0.
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321)) in
    let h1 headers path =
      let token = List.assoc_opt "authorization" headers |> Option.map (fun value ->
        String.sub value 7 (String.length value-7)) in
      http ~router ?token ~meth:"GET" ~path () in
    let h2 headers path = let status, _, body = wire_response ~handler ~headers path in
      status, Yojson.Safe.from_string body in
    f ~base_path ~state ~admin ~worker ["H1",h1;"H2",h2])

let test_authenticated_routes () = with_fixture (fun ~base_path ~state:_ ~admin ~worker protocols ->
  let prefix = "/api/v1/keepers/alpha/native-tasks/" in
  let records = prefix ^ "records?receiver_generation=receiver&session_id=session" in
  List.iter (fun (name,send) ->
    List.iter (fun path ->
      List.iter (fun (headers,expected) ->
        let status,_ = send headers path in check int (name ^ " authorization") expected status)
        [[],401;["authorization","Bearer invalid"],401;
         ["authorization","Bearer " ^ worker],403]) [prefix ^ "receivers";prefix ^ "hints";records];
    let headers = ["authorization","Bearer " ^ admin] in
    let hint_status,hint_body=send headers (prefix ^ "hints") in
    check int (name ^ " authenticated hints") 200 hint_status;
    let hint_decoded=require_ok Read.decode_error_to_string (Read.of_json hint_body) in
    let hint_page=require_ok Read.decode_error_to_string
      (Read.hints_of_response ~keeper_name:"alpha" hint_decoded) in
    check int (name ^ " cold hints never create storage") 0 (List.length hint_page.hints);
    let bad_hint_status,_=send headers (prefix ^ "hints?extra=1") in
    check int (name ^ " strict hint query") 400 bad_hint_status;

    let status,body = send headers records in
    check int (name ^ " missing is not empty success") 404 status;
    check string "missing code" "store_missing" Yojson.Safe.Util.(body |> member "error" |> to_string);
    let decoded = require_ok Read.decode_error_to_string (Read.of_json body) in
    (match decoded with
     | Read.Failure {error=Read.Store_missing;health=Some (Read.Process_only _)} -> ()
     | _ -> fail "missing store lost its typed error or process health");
    check bool "shared error serializer and decoder round-trip actual HTTP body" true
      (Read.to_json decoded=body);
    List.iter (fun query -> let status,_ = send headers (records ^ query) in
      check int (name ^ " strict query") 400 status)
      ["&unknown=x";"&receiver_generation=other";"&store_id=x";
       "&after_sequence=0";"&store_id=x&after_sequence=-1";
       "&store_id=x&after_sequence=01";"&base_path=/other"];
    let status,body = send headers (prefix ^ "receivers") in
    check int (name ^ " discovery") 200 status;
    check string "no completeness assertion" "unknown"
      Yojson.Safe.Util.(body |> member "provider_completeness" |> to_string);
    let decoded = require_ok Read.decode_error_to_string (Read.of_json body) in
    let inventory = require_ok Read.decode_error_to_string
        (Read.receivers_of_response ~keeper_name:"alpha" decoded) in
    check int "actual authenticated empty discovery decodes as empty success" 0
      (List.length inventory.receivers);
    check bool "shared discovery serializer and decoder round-trip HTTP body" true
      (Read.to_json decoded=body);
    (match Read.receivers_of_response ~keeper_name:"foreign" decoded with
     | Error Read.Scope_mismatch -> ()
     | _ -> fail "another Keeper's discovery was accepted");
    let set name value = function
      | `Assoc fields -> `Assoc ((name,value)::List.remove_assoc name fields)
      | _ -> fail "fixture expected object" in
    let health = Yojson.Safe.Util.member "observed_persistence_health" body in
    let warning = `Assoc ["operation",`String "close";"status",`String "cleanup_failed"] in
    let issue = `Assoc ["receiver",`Null;"event_uuid",`String "opaque issue";
      "error",`Null;"cleanup_failures",`List [warning]] in
    let with_issues issues = set "observed_persistence_health"
        (set "issues" (`List issues) health) body in
    let nullable = with_issues [issue] in
    let decoded = require_ok Read.decode_error_to_string (Read.of_json nullable) in
    (match decoded with
     | Read.Receivers {health=Read.Process_only {issues=[issue];_};_} ->
         check bool "required nullable health leaves remain absent facts" true
           (issue.receiver=None && issue.error=None && issue.cleanup_failures=["close"])
     | _ -> fail "nullable health diagnostics were flattened");
    (* JSON object order is irrelevant; canonical round-trip retains all facts. *)
    check bool "nullable diagnostics survive re-encoding" true
      (Read.of_json (Read.to_json decoded)=Ok decoded);
    let rejected value = match Read.of_json value with
      | Error _ -> () | Ok _ -> fail "malformed closed native-task envelope decoded" in
    rejected (set "schema" (`String "other") body);
    rejected (set "provider_completeness" `Null body);
    rejected (set "observed_persistence_health" `Null body);
    rejected (set "unknown" (`Bool true) body);
    (match body with `Assoc fields -> rejected (`Assoc (("schema",`String "masc.native_tasks.receivers.v1")::fields))
     | _ -> fail "response was not an object");
    rejected (with_issues [set "receiver" (`Assoc ["receiver_generation",`String "g";"session_id",`Null]) issue]);
    rejected (with_issues [set "error" (`String "store_missing") issue]);
    rejected (with_issues [set "cleanup_failures" (`List [set "status" (`String "ok") warning]) issue]);
    rejected (with_issues [match issue with `Assoc fields -> `Assoc (List.remove_assoc "error" fields)
      | _ -> fail "issue was not an object"])) protocols;
  let reader = require_ok Keeper_native_task_journal.error_to_string
    (Keeper_native_task_journal.open_reader ~base_path ~keeper_name:"alpha"
      ~receiver_generation:"receiver" ~session_id:"session") in
  let path = Keeper_native_task_journal.path reader in
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun out -> output_string out "not a database");
  List.iter (fun (name,send) -> let status,_ = send ["authorization","Bearer " ^ admin] records in
    check int (name ^ " corrupt storage unavailable") 503 status;
    let _, body = send ["authorization","Bearer " ^ admin] (prefix ^ "receivers") in
    let decoded = require_ok Read.decode_error_to_string (Read.of_json body) in
    let inventory = require_ok Read.decode_error_to_string
        (Read.receivers_of_response ~keeper_name:"alpha" decoded) in
    (match inventory.receivers with
     | [{storage=Read.Failed Read.Store_unavailable;_}] -> ()
     | _ -> fail "failed receiver disappeared or became empty/audited success");
    match body with
    | `Assoc fields ->
        let entries=Yojson.Safe.Util.(body |> member "receivers" |> to_list) in
        let duplicate=`Assoc (("receivers",`List (entries @ entries))::List.remove_assoc "receivers" fields) in
        (match Read.of_json duplicate with Error Read.Duplicate_receiver -> ()
         | _ -> fail "duplicate receiver was accepted")
    | _ -> fail "discovery was not an object") protocols)

let test_unchecked_hint_codec () =
  let health = `Assoc ["coverage",`String "issues_observed_in_this_process_only";
    "process_epoch",`String "process";"historical_failure_coverage",`String "unknown";
    "issues",`List []] in
  let entry = `Assoc ["receiver_generation",`String "generation";"session_id",`String "session";
    "hint",`Assoc ["status",`String "unchecked";"store_id",`String "store";
      "through_sequence",`Int 3]] in
  let body = `Assoc ["schema",`String "masc.native_tasks.hints.v1";
    "keeper_name",`String "alpha";"hints",`List [entry];
    "historical_integrity",`String "unchecked";
    "provider_completeness",`String "unknown";"historical_persistence_failures",`String "unknown";
    "cleanup_failures",`List [];"observed_persistence_health",health] in
  let decoded=require_ok Read.decode_error_to_string (Read.of_json body) in
  let hints=require_ok Read.decode_error_to_string
    (Read.hints_of_response ~keeper_name:"alpha" decoded) in
  check int "hint preserved" 1 (List.length hints.hints);
  check bool "no audited discovery capability" true
    (Read.receivers_of_response ~keeper_name:"alpha" decoded=Error Read.Unexpected_response);
  check bool "no cross Keeper acceptance" true
    (Read.hints_of_response ~keeper_name:"other" decoded=Error Read.Scope_mismatch);
  check bool "round trip retains unchecked meaning" true (Read.of_json (Read.to_json decoded)=Ok decoded);
  let replace name value = match body with
    | `Assoc fields -> `Assoc ((name,value)::List.remove_assoc name fields)
    | _ -> fail "object expected" in
  let reject body = match Read.of_json body with Error _ -> () | Ok _ -> fail "unsafe hint accepted" in
  reject (replace "historical_integrity" (`String "audited"));
  reject (replace "hints" (`List [entry;entry]));
  reject (replace "hints" (`List [match entry with
    | `Assoc fields -> `Assoc (("hint",`Assoc ["status",`String "audited";
        "store_id",`String "store";"through_sequence",`Int 3])::List.remove_assoc "hint" fields)
    | _ -> fail "object expected"]));
  check bool "route parses exact hints endpoint" true
    (Api.route "/api/v1/keepers/alpha/native-tasks/hints"=Some (Api.Hints "alpha"))

let test_child_authenticated_routes () =
  let module Child_api = Server_dashboard_http_keeper_child_content in
  let module Child_read = Keeper_child_content_read in
  with_fixture (fun ~base_path ~state:_ ~admin ~worker protocols ->
    let prefix = "/api/v1/keepers/alpha/child-content/" in
    let records = prefix ^ "records?receiver_generation=receiver&session_id=session&client_uuid=client" in
    List.iter (fun (name, send) ->
      List.iter (fun path ->
        List.iter (fun (headers, expected) ->
          let status, _ = send headers path in
          check int (name ^ " Child token permission") expected status)
          [[],401; ["authorization","Bearer invalid"],401;
           ["authorization","Bearer " ^ worker],403])
        [prefix ^ "receivers"; prefix ^ "hints"; records];
      let headers = ["authorization","Bearer " ^ admin] in
      let status, body = send headers records in
      check int (name ^ " missing Child store is a refusal") 404 status;
      let decoded = require_ok Child_read.decode_error_to_string (Child_read.of_json body) in
      (match decoded with
       | Child_read.Failure {error=Child_read.Store_missing;coverage=Child_read.Unavailable} -> ()
       | _ -> fail "Child missing store fabricated retained health or empty records");
      check bool "Child missing response codec roundtrip" true (Child_read.to_json decoded=body);
      List.iter (fun query ->
        let status, _ = send headers (records ^ query) in
        check int (name ^ " Child strict query") 400 status)
        ["&unknown=x"; "&client_uuid=other"; "&store_id=x";
         "&after_sequence=0"; "&store_id=x&after_sequence=-1";
         "&store_id=x&after_sequence=01"; "&store_id=x&after_sequence=9007199254740992";
         "&base_path=/other"; "&keeper_name=other"];
      let status, _ = send headers
        (prefix ^ "records?receiver_generation=receiver&session_id=session") in
      check int (name ^ " Child client UUID is mandatory") 400 status;
      let status, _ = send headers (records ^ "&client_uuid=") in
      check int (name ^ " Child empty/duplicate client UUID is refused") 400 status;
      List.iter (fun endpoint ->
        let status, body = send headers (prefix ^ endpoint) in
        check int (name ^ " cold Child " ^ endpoint) 200 status;
        let decoded = require_ok Child_read.decode_error_to_string (Child_read.of_json body) in
        (match decoded with
         | Child_read.Receivers page when endpoint="receivers" ->
             check int "no Child receiver invented" 0 (List.length page.receivers)
         | Child_read.Hints page when endpoint="hints" ->
             check int "no Child hint invented" 0 (List.length page.hints)
         | _ -> fail "Child endpoint returned a different read contract");
        let status, _ = send headers (prefix ^ endpoint ^ "?extra=1") in
        check int (name ^ " Child discovery query refused") 400 status)
        ["receivers"; "hints"];
      check bool (name ^ " read-only Child cold paths do not create storage") false
        (Sys.file_exists (Filename.concat (Common.masc_dir_from_base_path ~base_path) "child-content-journals"));
      check bool "exact Child records route" true
        (Child_api.route (prefix ^ "records")=Some (Child_api.Records "alpha"))) protocols)

let () = run "native task authenticated read" ["registered routes",[
  test_case "H1/H2 auth, strict scope and failed storage" `Quick test_authenticated_routes;
  test_case "H1/H2 Child auth, ticket3, unknown coverage and read-only cold paths" `Quick test_child_authenticated_routes;
  test_case "unchecked hints cannot become audited reads" `Quick test_unchecked_hint_codec]]
