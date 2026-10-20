(** The installation question routes (RFC operator-quiz §4.6) through the real
    lane add-on router and token auth: the list beside the Keeper questions and
    the operator's answer. The questions are recorded in the Lane store the
    routes read; no worker runs. *)
open Alcotest
module Routes = Server_routes_http_routes_lane_addons
module Asks = Masc.Lane_addon_asks
module Ask = Masc.Keeper_ask

let require = function Ok value -> value | Error detail -> fail detail

let loopback () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"

let dispatch ~sw ~clock ~state ~token ?body target =
  Server_request_authority.with_current (loopback ()) (fun () ->
    let router = Routes.add_routes ~sw ~clock (Masc.Http_server_eio.Router.create ()) in
    Server_auth.publish_server_state state;
    let output = Buffer.create 4096 in
    let connection = Httpun.Server_connection.create (fun reqd ->
      Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd) in
    let meth, payload = match body with None -> "GET", "" | Some json -> "POST", Yojson.Safe.to_string json in
    let raw = Printf.sprintf
        "%s %s HTTP/1.1\r\nHost: 127.0.0.1:8935\r\nOrigin: http://127.0.0.1:8935\r\n\
         Authorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
        meth target token (String.length payload) payload in
    let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw) raw in
    ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
    let rec drain () = match Httpun.Server_connection.next_write_operation connection with
      | `Write iovecs ->
          let written = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
            Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
            total + iov.len) 0 iovecs in
          Httpun.Server_connection.report_write_result connection (`Ok written);
          drain ()
      | `Yield when Buffer.length output = 0 ->
          let ready, resolve = Eio.Promise.create () in
          Httpun.Server_connection.yield_writer connection (fun () -> Eio.Promise.resolve resolve ());
          Eio.Promise.await ready;
          drain ()
      | `Yield | `Close _ -> () in
    drain ();
    Server_auth.clear_server_state ();
    let raw = Buffer.contents output in
    let boundary = Str.search_forward (Str.regexp_string "\r\n\r\n") raw 0 in
    let status = int_of_string (List.nth (String.split_on_char ' ' raw) 1) in
    status, Yojson.Safe.from_string (String.sub raw (boundary + 4) (String.length raw - boundary - 4)))

let member = Yojson.Safe.Util.member
let text key json = member key json |> Yojson.Safe.Util.to_string
let rows json = member "asks" json |> Yojson.Safe.Util.to_list
let row_ids json = List.map (text "ask_id") (rows json)

let questions =
  require
    (Asks.questions_of_json
       (`List
          [ `Assoc
              [ "question_id", `String "q1"; "header", `String "Ledger"; "prompt", `String "What does the ledger record?"
              ; "choices", `List [ `Assoc [ "choice_id", `String "a"; "label", `String "Facts"; "description", `Null ]
                                 ; `Assoc [ "choice_id", `String "b"; "label", `String "Plans"; "description", `Null ] ]
              ; "mode", `String "single"; "free_text", `Assoc [ "kind", `String "choices_only" ] ] ]))

let ask id = require (Asks.ask ~ask_id:id ~declaration_id:"quiz" ~title:"Operator quiz" ~questions
                        ~context:"From the ledger" ~asked_at:1.0 ())

let answer_body ?(declaration_id = "quiz") ?(extra = []) ~ask_id choice =
  `Assoc ([ "declaration_id", `String declaration_id; "ask_id", `String ask_id
          ; "answers", `List [ `Assoc [ "question_id", `String "q1"
                                      ; "response", `Assoc [ "kind", `String "chose"
                                                           ; "choice_ids", `List [ `String choice ] ] ] ] ]
          @ extra)

(* One workspace with token auth on, an operator and a worker token, and the
   installation's store holding [ids] as open questions. *)
let with_routes ids f =
  let base_path = Filename.temp_file "lane-ask-routes-" "" in
  Sys.remove base_path; Unix.mkdir base_path 0o700;
  let base_path = Unix.realpath base_path in
  Fun.protect ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base_path) (fun () ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let token role name = match Auth.create_token base_path ~agent_name:name ~role with
      | Ok (token, _) -> token
      | Error err -> failf "create_token failed: %s" (Masc_domain.masc_error_to_string err) in
    let operator = token Masc_domain.Admin "operator" and worker = token Masc_domain.Worker "keeper" in
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 30. (fun () ->
      Eio.Switch.run (fun sw ->
      Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
        Masc.Lane_addon_runtime.For_testing.reset ();
        let config = Masc.Mcp_server.workspace_config state in
        let store = Masc.Lane_addon_store.create
            ~root:(Filename.concat (Masc.Workspace.masc_dir config) "lane-addons") in
        List.iter (fun id -> check bool ("asked " ^ id) true (Asks.record store (ask id) = Ok Asks.Recorded)) ids;
        let clock = (Eio.Stdenv.clock env :> float Eio.Time.clock_ty Eio.Resource.t) in
        f ~config ~store ~call:(fun ?(token = operator) ?body target ->
          dispatch ~sw ~clock ~state ~token ?body target) ~worker)))))

let test_the_list_shows_open_questions_in_the_keeper_form () =
  with_routes [ "quiz-1" ] (fun ~config ~store:_ ~call ~worker ->
    let status, body = call "/api/v1/lane-addons/asks" in
    check int "listed" 200 status;
    (match rows body with
     | [ row ] ->
         check string "the installation" "quiz" (text "declaration_id" row);
         check string "asked by its title" "Operator quiz" (text "title" row);
         check string "with its context" "From the ledger" (text "context" row);
         check string "open" "open" (text "state" (member "resolution" row));
         let question = match member "questions" row |> Yojson.Safe.Util.to_list with
           | [ question ] -> question | _ -> fail "one question" in
         check bool "the Keeper question form" true
           (Yojson.Safe.equal question (Masc.Keeper_ask_operator_projection.ask_question_json (List.hd questions)))
     | _ -> fail "one open question");
    let status, _ = call ~token:worker "/api/v1/lane-addons/asks" in
    check int "a reader may list" 200 status;
    let encode = Uri.pct_encode ~component:`Query_value in
    let base = config.Masc.Workspace.base_path and root = Unix.realpath (Masc.Workspace.masc_dir config) in
    let bound other = Printf.sprintf "/api/v1/lane-addons/asks?expected_base_path=%s&expected_masc_root=%s"
        (encode (base ^ other)) (encode root) in
    check int "bound to this workspace" 200 (fst (call (bound "")));
    check int "bound to another workspace" 409 (fst (call (bound "-other")));
    check int "an unknown parameter" 400 (fst (call "/api/v1/lane-addons/asks?declaration_id=quiz")))

let test_the_operator_answers_once () =
  with_routes [ "quiz-1" ] (fun ~config:_ ~store:_ ~call ~worker ->
    let post ?token body = call ?token ~body "/api/v1/lane-addons/ask-answer" in
    check int "a Keeper may not answer for the operator" 403 (fst (post ~token:worker (answer_body ~ask_id:"quiz-1" "a")));
    let status, body = post (answer_body ~ask_id:"quiz-1" "c") in
    check int "an answer that fits no choice" 400 status;
    check int "with its reason" 1 (List.length (member "invalid_answers" body |> Yojson.Safe.Util.to_list));
    check int "an unknown field" 400 (fst (post (answer_body ~extra:[ "name", `String "x" ] ~ask_id:"quiz-1" "a")));
    check int "an unknown question" 404 (fst (post (answer_body ~ask_id:"quiz-9" "a")));
    check int "another installation's question" 404 (fst (post (answer_body ~declaration_id:"other" ~ask_id:"quiz-1" "a")));
    let status, body = post (answer_body ~extra:[ "session_id", `String "tui-1" ] ~ask_id:"quiz-1" "a") in
    check int "recorded" 200 status;
    check int "one answer" 1 (member "answer_count" body |> Yojson.Safe.Util.to_int);
    let status, body = post (answer_body ~ask_id:"quiz-1" "b") in
    check int "a second answer" 409 status;
    check string "says it was answered" "answered" (text "state" body);
    check (list string) "no longer open" [] (row_ids (snd (call "/api/v1/lane-addons/asks")));
    match rows (snd (call "/api/v1/lane-addons/asks?include_resolved=true")) with
    | [ row ] ->
        let resolution = member "resolution" row in
        check string "answered" "answered" (text "state" resolution);
        check (list string) "which question" [ "q1" ]
          (member "answered_question_ids" resolution |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_string)
    | _ -> fail "the answered question with include_resolved")

let test_a_withdrawn_question_refuses_its_answer () =
  with_routes [ "quiz-1"; "quiz-2" ] (fun ~config:_ ~store ~call ~worker:_ ->
    check bool "withdrawn" true
      (Asks.withdraw store ~declaration_id:"quiz" ~ask_id:"quiz-1" ~reason:"session ended" ~now:2.0 = Ok Asks.Withdrawn);
    let status, body = call ~body:(answer_body ~ask_id:"quiz-1" "a") "/api/v1/lane-addons/ask-answer" in
    check int "refused" 409 status;
    check string "says it was withdrawn" "withdrawn" (text "state" body);
    check (list string) "the open one stays listed" [ "quiz-2" ] (row_ids (snd (call "/api/v1/lane-addons/asks"))))

let () =
  run "Lane_addon_ask_routes"
    [ "routes",
      [ test_case "the list shows open questions in the Keeper form" `Quick
          test_the_list_shows_open_questions_in_the_keeper_form
      ; test_case "the operator answers once" `Quick test_the_operator_answers_once
      ; test_case "a withdrawn question refuses its answer" `Quick test_a_withdrawn_question_refuses_its_answer ] ]
