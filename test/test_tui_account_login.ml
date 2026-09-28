open Alcotest
module Login = Masc_tui_account_login
let session = String.make 64 'a'
let account = String.make 64 'b'
let other = String.make 64 'c'
let provider : Login.provider = {id="codex";label="Codex";client=Login.Codex}
let ok = function Ok value -> value | Error message -> fail message
let model i : Login.model = {id=string_of_int i;label="model " ^ string_of_int i;context=Some 32768;tools=Some true}
let frame name data = "event: " ^ name ^ "\r\ndata: " ^ Yojson.Safe.to_string data ^ "\r\n\r\n"
let started = frame "started" (`Assoc ["integration_id",`String "codex";"login_id",`String session;"account_ref",`String account])
let complete = frame "complete" (`Assoc ["integration_id",`String "codex";"account_ref",`String account;
  "authentication",`String "authenticated";"invocation_verified",`Bool false])
let inventory = `Assoc ["setup_revision",`String "revision";"default_runtime_selection", `List [`String "primary"; `String "fallback"];
  "runtimes",`List [`Assoc ["id",`String "unrelated"];`Assoc ["id",`String "fallback"];`Assoc ["id",`String "primary"]];
  "integrations",`List (List.map (fun (id,protocol) -> `Assoc ["id",`String id;"display_name",`String id;"protocol",`String protocol])
    ["codex","codex-app-server";"claude-code","claude-code";"muse-code","muse-serve";"antigravity","antigravity-cli"])]
let decoder_fragments () =
  let events=ref [] in
  let feed, finished = Login.decoder ~integration_id:"codex" (fun event -> events:=event :: !events) in
  let output=frame "output" (`Assoc ["stream",`String "stdout";"text",`String "browser code 안내"]) in
  String.iter (fun c -> feed (String.make 1 c)) (started ^ output ^ frame "input_ready" (`Assoc []) ^ complete);
  check bool "terminal event survives byte fragmentation" true (finished ());
  check bool "ordered events preserve Unicode and identity" true
    (List.rev !events=[Login.Started(session,Some account);Login.Output "browser code 안내";Login.Input_ready;Login.Complete(account,Login.Authenticated)]);
  feed output;
  check int "nothing can follow terminal completion" 4 (List.length !events)
let decoder_failures () =
  List.iter (fun invalid ->
    let events=ref [] in
    let feed,finished=Login.decoder ~integration_id:"codex" (fun event -> events:=event :: !events) in
    feed started;feed invalid;feed complete;
    check bool "invalid event permanently fails stream" true (finished ());
    check bool "no completion after failure" true (List.rev !events=[Login.Started(session,Some account);Login.Login_error]))
    ["event: output\ndata: {\n\n";frame "output" (`Assoc ["stream",`String "unknown";"text",`String "x"]);
     frame "complete" (`Assoc ["integration_id",`String "codex";"account_ref",`String account;"invocation_verified",`Bool false])];
  let feed,finished=Login.decoder ~integration_id:"codex" (fun _ -> ()) in
  feed started; feed "event: complete\ndata: {";
  check bool "truncated EOF is not completion" false (finished ())
let account_and_default () =
  List.iter (fun (requested,client) ->
    let t=Login.create requested in ok (Login.inventory t inventory);
    check bool "requested client selected" true ((List.nth t.providers t.cursor).client=client))
    ["codex",Login.Codex;"claude",Login.Claude;"muse",Login.Muse;"antigravity",Login.Antigravity];
  let unknown=Login.create "not-a-client" in
  check bool "unknown client refused" true (Result.is_error (Login.inventory unknown inventory));
  let t=Login.create "codex" in ok (Login.inventory t inventory);t.provider<-Some provider;t.account_ref<-Some account;
  let body=Login.save_body t (model 0) None in
  let open Yojson.Safe.Util in
  check string "current default stays first" "primary" (body |> member "selection" |> to_list |> List.hd |> member "runtime_id" |> to_string);
  check (list string) "only declared fallback order is preserved" ["primary"; "fallback"] t.existing;
  check int "save excludes unrelated enabled runtimes" 3 (body |> member "selection" |> to_list |> List.length);
  check string "selected account survives model save" account
    (body |> member "connections" |> to_list |> List.hd |> member "source" |> member "account_ref" |> to_string);
  check bool "slash login is never Keeper text" true (Masc_tui_command.parse "/login muse"=Masc_tui_command.Account_login "muse")
let input_and_epoch () =
  let t=Login.create "codex" in t.phase<-Login.Logging;t.generation<-2;t.login_id<-Some session;
  Login.paste t "private-code";
  check bool "render masks private input" false (List.exists (fun line -> line="private-code" || String.ends_with ~suffix:"private-code" line) (Login.lines t));
  (match Login.key t "\r" with
   | Login.Input (_, `Assoc fields) -> check bool "input goes to dedicated endpoint payload" true (List.assoc_opt "text" fields=Some (`String "private-code"))
   | _ -> fail "code was not submitted");
  check string "submitted code cleared" "" t.draft;
  ignore (Login.event ~generation:1 t Login.Input_ready);
  check bool "late previous input ACK cannot unlock new input" true t.input_pending;
  ignore (Login.event ~generation:1 t (Login.Complete(other,Login.Authenticated)));
  check bool "late account cannot replace current attempt" true (t.account_ref=None && t.phase=Login.Logging);
  ignore (Login.event ~generation:2 t Login.Input_ready);
  check bool "actual terminal Tab forwarded" true (Login.key t "\t"=Login.Input (2, `Assoc ["kind",`String "key";"key",`String "tab"]));
  check bool "cancel available while input pending" true (Login.key t "\003"=Login.Cancel)
let inventory_selection_contract () =
  let fields = match inventory with `Assoc fields -> List.remove_assoc "default_runtime_selection" fields | _ -> [] in
  List.iter (fun extra ->
    let t = Login.create "codex" in
    check bool "missing or invalid configured fallback selection is refused" true
      (Result.is_error (Login.inventory t (`Assoc (extra @ fields)))))
    [[]; ["default_runtime_selection", `String "primary"];
     ["default_runtime_selection", `List [`String "missing"]];
     ["default_runtime_selection", `List [`String "primary"; `String "primary"]];
     ["default_runtime_selection", `List [`String ""]]];
  let fresh = Login.create "codex" in
  ok (Login.inventory fresh (`Assoc (("default_runtime_selection", `List []) :: fields)));
  check (list string) "fresh setup has no inferred fallback" [] fresh.existing
let failed_before_started () =
  let t = Login.create "codex" in t.provider <- Some provider; t.phase <- Login.Logging;
  let feed, finished = Login.decoder ~integration_id:"codex"
    (fun event -> ignore (Login.event ~generation:0 t event)) in
  feed (frame "error" (`Assoc ["integration_id", `String "codex"; "login_id", `String session;
    "account_ref", `String account; "invocation_verified", `Bool false; "status", `String "failed"]));
  check bool "spawn failure is terminal but not successful" true (finished () && t.phase=Login.Failed);
  check bool "receipt can be requested before any started frame" true (Login.key t "r"=Login.Recover);
  check (option string) "failed prepared account remains available" (Some account) t.account_ref;
  check (option string) "receipt identity retained" (Some session) t.login_id
let retry_early_input () =
  List.iter (fun existing ->
    let t = Login.create "codex" in
    t.provider <- Some provider; t.account_ref <- Some account;
    t.login_id <- Some session; t.phase <- Login.Failed; t.generation <- 2;
    let previous = Login.begin_attempt t provider ~existing in
    check (option string) "retry captures only explicitly selected account"
      (if existing then Some account else None) previous;
    check (option string) "new attempt never retains previous session" None t.login_id;
    Login.paste t "early-private-code";
    List.iter (fun key ->
      check bool "no input before new server identity" true (Login.key t key = Login.Nothing);
      check string "early submit retains code draft" "early-private-code" t.draft;
      check bool "early submit does not await an impossible ACK" false t.input_pending)
      ["\r"; "up"; "down"; "\t"; "\004"];
    ignore (Login.event ~generation:1 t (Login.Started (session, Some other)));
    check (option string) "old started frame cannot reopen previous session" None t.login_id;
    ignore (Login.event ~generation:2 t (Login.Started (other, Some account)));
    check (option string) "input targets the new server session" (Some other) t.login_id;
    check bool "preserved draft submits once ready" true
      (Login.key t "\r" = Login.Input (1, `Assoc ["kind", `String "text"; "text", `String "early-private-code"]));
    check string "submitted draft cleared" "" t.draft;
    check bool "submission waits for actual ACK" true t.input_pending)
    [true; false]
let viewport_and_receipt () =
  let t=Login.create "codex" in t.phase<-Login.Models;t.models<-List.init 30 model;
  List.iter (fun cursor -> t.cursor<-cursor;
    check bool "selected model visible in short viewport" true
      (List.mem ("> model " ^ string_of_int cursor) (Login.visible_lines ~height:4 t))) [0;15;29];
  t.provider<-Some provider;t.login_id<-Some session;t.account_ref<-Some account;
  let receipt=`Assoc ["login_id",`String session;"integration_id",`String "codex";"invocation_verified",`Bool false;
    "status",`String "complete";"account_ref",`String other] in
  check bool "completion without auth observation rejected" true (Result.is_error (Login.receipt t receipt));
  check (option string) "bad receipt cannot replace selected account" (Some account) t.account_ref
let unicode_and_late_input_response () =
  let t=Login.create "codex" in t.phase<-Login.Logging;t.login_id<-Some session;
  List.iter (fun scalar -> ignore (Login.key t scalar)) ["한";"😀";" ";"é"];
  check string "typed scalar and space preserved" "한😀 é" t.draft;
  ignore (Login.key t "\127");
  check string "backspace removes a whole scalar" "한😀 " t.draft;
  check bool "draft remains valid UTF8" true (String.is_valid_utf_8 t.draft);
  let first=match Login.key t "\r" with Login.Input (sequence,_) -> sequence | _ -> fail "input" in
  ignore (Login.event ~generation:0 t Login.Input_ready);
  Login.paste t "new-draft";
  Login.input_response ~sequence:first t (Error "late HTTP failure after native ACK");
  check string "acknowledged input failure cannot erase current draft" "new-draft" t.draft;
  let second=match Login.key t "\r" with Login.Input (sequence,_) -> sequence | _ -> fail "input" in
  Login.input_response ~sequence:first t (Error "old HTTP failure after next submission");
  check bool "old failure cannot release newer pending input" true t.input_pending;
  Login.input_response ~sequence:second t (Error "current rejected input");
  check bool "current failure allows correction" false t.input_pending
let verified_save_refresh () =
  let t=Login.create "codex" in ok (Login.inventory t inventory);t.phase<-Login.Finished;
  Login.refresh_saved t (Error "network unavailable");
  check bool "transport failure cannot revoke verified save" true (t.phase=Login.Finished);
  check bool "retry refreshes inventory instead of old login receipt" true (Login.key t "r"=Login.Refresh_saved);
  Login.refresh_saved t (Ok (`Assoc []));
  check bool "bad inventory cannot revoke verified save" true (t.phase=Login.Finished);
  Login.refresh_saved t (Ok inventory);
  check bool "successful refresh retains saved screen" true (t.phase=Login.Finished)
let missing_model_context () =
  List.iter (fun client ->
    let t=Login.create "" in let unknown={ (model 0) with context=None } in
    t.provider<-Some {provider with client};t.phase<-Login.Models;t.models<-[unknown];
    let action=Login.key t "\r" in
    match client with
    | Login.Antigravity -> check bool "native observation available" true (action=Login.Prepare unknown)
    | Login.Muse ->
      check bool "unreported Muse context is not invented" true (action=Login.Nothing && t.phase=Login.Models);
      check bool "Muse can refresh native metadata" true (Login.key t "r"=Login.Discover)
    | Login.Codex | Login.Claude ->
      check bool "explicit documented limit requested" true (action=Login.Nothing && t.phase=Login.Documented_context unknown);
      check bool "empty context cannot save" true (Login.key t "\r"=Login.Nothing);
      Login.paste t "32768";
      (match Login.key t "\r" with
       | Login.Save (selected,None) -> check (option int) "operator documented value still goes through save verification" (Some 32768) selected.context
       | _ -> fail "documented context did not reach verification"))
    [Login.Codex;Login.Claude;Login.Antigravity;Login.Muse]
let named_default_identity () =
  let fields=match inventory with `Assoc fields -> List.remove_assoc "default_runtime_id" fields | _ -> [] in
  let t=Login.create "codex" in
  ok (Login.inventory t (`Assoc (("default_runtime_id",`String "named-lane") :: fields)));
  t.provider<-Some provider;t.account_ref<-Some account;
  let body=Login.save_body t (model 0) None in
  let open Yojson.Safe.Util in
  check string "named default remains an explicit lane identity" "named-lane" (body |> member "default_runtime_id" |> to_string);
  check bool "lane identity is not submitted as a concrete candidate" false
    (List.exists (fun row -> row |> member "runtime_id" = `String "named-lane") (body |> member "selection" |> to_list))
let pasted_credential_bytes () =
  List.iter (fun ending ->
    let t=Login.create "codex" in t.phase<-Login.Logging;t.login_id<-Some session;
    let secret="  한😀  é private-code  " in
    Login.paste t (secret ^ ending);
    check string "pasted spaces and Unicode are byte exact" secret t.draft;
    check bool "dedicated input payload preserves bytes" true
      (Login.key t "\r"=Login.Input (1,`Assoc ["kind",`String "text";"text",`String secret])))
    ["";"\r";"\n";"\r\n"];
  List.iter (fun invalid ->
    let t=Login.create "codex" in t.phase<-Login.Logging;t.draft<-"existing";
    Login.paste t invalid;
    check string "unsupported paste never alters existing credential" "existing" t.draft;
    check bool "rejected paste reports its reason" true (t.notice <> (Login.create "codex").notice))
    ["first\nsecond";"first\rsecond";"first\tsecond";"secret\n\n";"nul\000";"escape\027";"delete\127";"\194\128";"\255"]
let failed_save_refresh () =
  let t=Login.create "codex" in ok (Login.inventory t inventory);
  t.provider<-Some provider;t.account_ref<-Some account;t.login_id<-Some session;
  t.models<-[model 0;model 1];t.cursor<-1;t.phase<-Login.Saving;
  let selected={ (model 1) with context=Some 65536 } in
  Login.save_failed t selected "save refused";
  check bool "save failure requests current configuration despite login receipt" true (Login.key t "r"=Login.Refresh_retry);
  Login.refresh_retry t (Error "network unavailable");
  check bool "failed refresh remains retriable and cannot save stale config" true
    (t.phase=Login.Failed && Login.key t "r"=Login.Refresh_retry && Login.key t "\r"=Login.Nothing);
  let fields=match inventory with `Assoc fields -> fields | _ -> [] in
  let current=`Assoc (["setup_revision",`String "new-revision";"default_runtime_id",`String "new-default";
    "default_runtime_selection",`List [`String "fallback"]] @
    List.filter (fun (name,_) -> not (List.mem name ["setup_revision";"default_runtime_id";"default_runtime_selection"])) fields) in
  Login.refresh_retry t (Ok current);
  check bool "refresh awaits deliberate retry on retained model" true (t.phase=Login.Models && t.cursor=1);
  check (option string) "refresh retains authenticated account" (Some account) t.account_ref;
  match Login.key t "\r" with
  | Login.Save (chosen,None) ->
    check string "same model retained" selected.id chosen.id;
    check (option int) "documented context survives failed save" selected.context chosen.context;
    let body=Login.save_body t chosen None in
    let open Yojson.Safe.Util in
    check string "retry uses new revision" "new-revision" (body |> member "revision" |> to_string);
    check string "retry preserves new default" "new-default" (body |> member "default_runtime_id" |> to_string);
    check (list string) "retry uses current selection" ["fallback"] t.existing;
    check string "retry uses same account" account
      (body |> member "connections" |> to_list |> List.hd |> member "source" |> member "account_ref" |> to_string)
  | _ -> fail "refreshed save was not offered"
let () = run "TUI account login" ["workflow",[
  test_case "pasted credentials preserve bytes and reject controls" `Quick pasted_credential_bytes;
  test_case "failed save refreshes revision and retains model" `Quick failed_save_refresh;
  test_case "named default lane remains selected" `Quick named_default_identity;
  test_case "Unicode and late input HTTP response" `Quick unicode_and_late_input_response;
  test_case "verified save survives refresh failure" `Quick verified_save_refresh;
  test_case "unknown context follows supported provider route" `Quick missing_model_context;
  test_case "fragmented remote login" `Quick decoder_fragments;
  test_case "malformed and unfinished streams" `Quick decoder_failures;
  test_case "explicit provider and preserved default" `Quick account_and_default;
  test_case "private input and superseded attempt" `Quick input_and_epoch;
  test_case "declared fallback inventory contract" `Quick inventory_selection_contract;
  test_case "spawn failure retains recovery receipt" `Quick failed_before_started;
  test_case "retry preserves early input until a new session starts" `Quick retry_early_input;
  test_case "visible cursor and recovery identity" `Quick viewport_and_receipt]]
