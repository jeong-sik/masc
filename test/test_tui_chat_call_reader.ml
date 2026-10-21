open Alcotest
open Masc_tui_types
module Reader = Masc_tui_chat_call_reader
module Fetched = Masc_tui_fetched
module Reading = Masc_tui_detail_reading
module Decode = Masc.Tui_decode
let choice execution_id = {Reader.execution_id;tool="Execute";args="original arguments";subject=Some execution_id}
let row ?(keeper="alpha") execution_id output =
  `Assoc ["ts",`Float 1.;"keeper",`String keeper;"tool",`String "Execute";
    "execution_id",`String execution_id;"input",`String "original arguments";
    "output",`String output;"wire_outcome",`String "ok"]
let response ?(keeper="alpha") ?entry execution_id output =
  `Assoc ["keeper",`String keeper;"execution_id",`String execution_id;
    "entry",(match entry with Some entry -> entry | None -> row execution_id output)]
let decode id output = match Decode.decode_keeper_call_exact ~requested_keeper:"alpha"
  ~execution_id:id (response id output) with Ok call -> call | Error error -> fail error
let start reader = match Reader.start reader with
  | reader,Some request -> reader,request
  | _,None -> fail "original request was not started"
let value reader = Fetched.value (Reader.observation reader)
let test_original_request () =
  let execution_id="old/exec?&=é" in
  let uri=Uri.of_string (Reader.path ~keeper:"alpha beta" ~execution_id) in
  check (list (pair string (list string))) "only exact execution query"
    ["execution_id",[execution_id]] (Uri.query uri);
  check string "keeper is a path segment" "/api/v1/keepers/alpha%20beta/tool-calls" (Uri.path uri);
  let reader=Reader.create (List.init 130 (fun i -> choice (string_of_int i))) in
  let reader=Reader.choose 129 reader in
  check (option string) "selection beyond recent-list window stays exact" (Some "129")
    (Option.map (fun choice -> choice.Reader.execution_id) (Reader.selected reader));
  check (option string) "choice keeps original target" (Some "129")
    (Option.bind (Reader.selected reader) (fun choice -> choice.Reader.subject));
  check (option string) "choice keeps original arguments" (Some "original arguments")
    (Option.map (fun choice -> choice.Reader.args) (Reader.selected reader));
  let _,request=start reader in
  check string "request is the chosen original" "129" (Fetched.request_key request)
let test_exact_decode () =
  let output=String.concat "\n" (List.init 300 (fun i -> string_of_int i)) in
  let call=decode "original" output in
  check (option string) "full raw output is preserved" (Some output) call.kc_output;
  List.iter (fun json ->
    check bool "identity mismatch is refused" true
      (Result.is_error (Decode.decode_keeper_call_exact ~requested_keeper:"alpha" ~execution_id:"original" json)))
    [response ~keeper:"beta" "original" output;
     response "different" output;
     response ~entry:(row "different" output) "original" output;
     response ~entry:(row ~keeper:"beta" "original" output) "original" output]
let test_superseding_and_close () =
  let reader,old=start (Reader.create [choice "original"]) in
  let reader,current=start reader in
  check bool "refresh during initial loading still owns a new read" true (Reader.pending reader);
  check bool "refresh has a new generation" false
    (Fetched.same_request ~equal:String.equal old current);
  let late=Reader.complete reader old (Ok (decode "original" "late")) in
  check bool "late success cannot settle replacement" true (Reader.pending late);
  let closed=Reader.back late in
  let closed=Reader.complete closed current (Error "late failure") in
  check bool "closed reader cannot be reopened by late failure" true (Reader.choosing closed);
  check bool "closed reader has no pending admission" false (Reader.pending closed)
let test_failure_retains_result_and_scroll () =
  let reader,request=start (Reader.create [choice "original"]) in
  let reader=Reader.complete reader request (Ok (decode "original" "complete original")) in
  let reader=Reader.move ~count:500 ~height:20 (Reading.By 80) reader in
  let reader,request=start reader in
  check bool "refresh exposes pending beside retained observation" true (Reader.pending reader);
  check int "refresh preserves independent offset" 80
    (Reading.scroll ~count:500 ~height:20 (Reader.document reader));
  let reader=Reader.complete reader request (Error "HTTP 503") in
  check int "failed refresh preserves offset" 80
    (Reading.scroll ~count:500 ~height:20 (Reader.document reader));
  check (option string) "last original result survives failure" (Some "complete original")
    (Option.bind (value reader) (fun call -> call.Decode.kc_output));
  check bool "refresh failure stays typed stale" true
    (match Reader.observation reader with Fetched.Stale (_,_) -> true | Absent | Loading | Ready _ | Failed _ -> false)
let test_original_body_refresh () =
  let content=String.concat "\n" (List.init 120 (fun i ->
    Printf.sprintf "원문 %03d 🙂" (i+1))) in
  let original=Decode.Original_body {source_id=String.make 64 'a';
    sha256=String.make 64 'b';recorded_bytes=String.length content;content} in
  List.iter (fun failure ->
    let initial={ (decode "original" "canonical preview") with Decode.kc_original=original } in
    let reader,request=start (Reader.create [choice "original"]) in
    let reader=Reader.complete reader request (Ok initial) in
    let reader=Reader.move ~count:500 ~height:20 (Reading.By 80) reader in
    let reader,request=start reader in
    check string "refresh stays bound to the original execution" "original"
      (Fetched.request_key request);
    let updated={ (decode "original" "new preview") with Decode.kc_original=failure } in
    let reader=Reader.complete reader request (Ok updated) in
    check int "source failure preserves reading offset" 80
      (Reading.scroll ~count:500 ~height:20 (Reader.document reader));
    (match Reader.observation reader with
     | Fetched.Stale (retained,_) ->
         check bool "complete source survives failed refresh" true (retained.kc_original=original);
         check (option string) "canonical preview is not overwritten by failed source"
           (Some "canonical preview") retained.kc_output
     | Absent | Loading | Ready _ | Failed _ -> fail "source failure erased the retained observation");
    let empty,request=start (Reader.create [choice "original"]) in
    let empty=Reader.complete empty request (Ok updated) in
    match Reader.observation empty with
    | Fetched.Ready observed ->
        check bool "initial source failure remains explicit" true (observed.kc_original=failure);
        check (option string) "initial failure still retains ledger preview"
          (Some "new preview") observed.kc_output
    | Absent | Loading | Stale _ | Failed _ -> fail "initial preview was lost")
    [Decode.Original_pending;Original_unavailable "trace not retained";Original_failed "HTTP 503"]
let state () =
  let state=create_state ~workspace:"reader-test" ~port:0 ~refresh_interval:0. () in
  let workspace={Decode.sid_version="test";sid_binary_commit="test";
    sid_binary_commit_age_s=None;sid_base_path=Masc.Tui_decode.Canonical_path.of_path "/workspace";sid_masc_root=Masc.Tui_decode.Canonical_path.of_path "/workspace/.masc";
    sid_executable_in_worktree=None;sid_state_ready=Some true;sid_uptime=None;
    sid_sse_clients=None;sid_gc=None;sid_scheduler=None} in
  state.server_identity <- Some workspace;
  state.workspace_identity <- Workspace_identity_match;
  state.view <- Keepers Keeper_message;
  state.msg_target_keeper_name <- Some "alpha";
  let origin={cco_workspace=workspace;cco_authority=state.workspace_authority;
    cco_reading=state.workspace_read_authority;cco_keeper="alpha"} in
  state.chat_call_reader <- Some (origin,Reader.create [choice "original"]);
  state
let request state = match begin_chat_call_read state with Some request -> request | None -> fail "no request"
let test_failed_retry_pending () =
  let reader,request=start (Reader.create [choice "original"]) in
  let reader=Reader.complete reader request (Error "HTTP 404") in
  let reader,_request=start reader in
  check bool "retry is pending" true (Reader.pending reader);
  check bool "retry keeps known no-value failure" true
    (match Reader.observation reader with Fetched.Failed _ -> true | Absent | Loading | Ready _ | Stale _ -> false)
let test_workspace_and_draft () =
  let state=state () in
  Masc_tui_message_input.insert state.msg_input "unsent draft";
  state.msg_scroll <- 51;
  state.msg_loaded_error <- Some "original history error";
  let history=state.msg_history and loaded=state.msg_loaded in
  let initial=request state in
  check bool "exact response applies" true
    (complete_chat_call_read state initial (Ok (decode "original" "full output")));
  check string "draft unchanged" "unsent draft" (Masc_tui_message_input.contents state.msg_input);
  check int "conversation scroll unchanged" 51 state.msg_scroll;
  check bool "original conversation unchanged" true (state.msg_history == history && state.msg_loaded == loaded);
  check (option string) "original failure unchanged" (Some "original history error") state.msg_loaded_error;
  let retired=request state in
  suspend_workspace_readings state;
  state.workspace_identity <- Workspace_identity_match;
  check bool "same workspace reconfirmation cannot apply retired reply" false
    (complete_chat_call_read state retired (Ok (decode "original" "late")));
  check bool "retired overlay stays closed" true (Option.is_none (current_chat_call_reader state))
let test_replacement_and_authority () =
  List.iter (fun replace ->
    let state=state () in let pending=request state in replace state;
    check bool "old owner cannot settle current state" false
      (complete_chat_call_read state pending (Error "late")))
    [ (fun state -> state.msg_target_keeper_name <- Some "beta");
      (fun state -> state.workspace_read_authority <- ref ());
      (fun state -> state.workspace_authority <- Workspace_authority 42);
      (fun state -> state.workspace_identity <- Workspace_identity_match_unconfirmed "lost");
      (fun state -> close_key_modals state) ]
let test_actual_enter_bytes () =
  let reader=Reader.create [choice "original"] in
  List.iter (fun byte ->
    let decoder=Masc_tui_input_decoder.create () in
    match Masc_tui_input_decoder.feed decoder byte with
    | [Masc_tui_input_decoder.Key key] ->
        check bool "decoded terminal Enter opens selected original" true
          (Reader.action ~key ~height:10 reader = Reader.Open)
    | [] | (Masc_tui_input_decoder.Key _ | Paste _ | Mouse_wheel _
              | Mouse_left_press _ | Mouse_left_drag _ | Mouse_left_release _
              | Reply _) :: _ ->
        fail "terminal byte did not decode to a single key") ['\r';'\n']
let test_plain_t_and_explicit_command () =
  check bool "ordinary t remains chat text" true
    (Masc_tui_command.parse "t" = Masc_tui_command.Say "t");
  check bool "calls is an explicit local action" true
    (Masc_tui_command.parse "/calls" = Masc_tui_command.Open_calls)
let test_captured_search_scope () =
  let reader,request=start (Reader.create [choice "original"]) in
  let reader=Reader.complete reader request (Ok (decode "original" "retained pitch")) in
  let searched=match Reader.search_key ~width:80 ~height:10 ~key:"/" reader with
    | Some reader -> Reader.search_insert ~width:80 ~height:10 ~text:"pitch" reader
    | None -> fail "opened original did not own search" in
  check (option string) "query belongs to the opened original" (Some "pitch")
    (Reading.search_query (Reader.document searched));
  let refreshed,_=start searched in
  check (option string) "same execution refresh retains query" (Some "pitch")
    (Reading.search_query (Reader.document refreshed));
  check (option string) "return to chooser clears result query" None
    (Reading.search_query (Reader.document (Reader.back refreshed)));
  check (option string) "search does not change original output" (Some "retained pitch")
    (Option.bind (value searched) (fun call -> call.Decode.kc_output))
let () = run "original chat call reader"
 ["requests",[test_case "exact selection and request" `Quick test_original_request;
              test_case "exact response identity and full payload" `Quick test_exact_decode];
  "ownership",[test_case "refresh loading and late close" `Quick test_superseding_and_close;
               test_case "retained result and offset" `Quick test_failure_retains_result_and_scroll;
               test_case "original source refresh retains body and offset" `Quick test_original_body_refresh;
               test_case "failed retry has independent pending" `Quick test_failed_retry_pending;
               test_case "workspace and original conversation" `Quick test_workspace_and_draft;
               test_case "replacement authority" `Quick test_replacement_and_authority];
  "input",[test_case "actual CR/LF selects an original" `Quick test_actual_enter_bytes;
           test_case "ordinary t and explicit calls" `Quick test_plain_t_and_explicit_command;
           test_case "captured document search scope" `Quick test_captured_search_scope]]
