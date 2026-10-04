open Alcotest
module Login = Masc_tui_account_login
let session = String.make 64 'a'
let account = String.make 64 'b'
let other = String.make 64 'c'
let provider : Login.provider = {id="codex";label="Codex";client=Login.Codex;origin=Login.Configured;enabled=true;setup_supported=true}
let ok = function Ok value -> value | Error message -> fail message
let model i : Login.model = {id=string_of_int i;label="model " ^ string_of_int i;context=Some 32768;tools=Some true}
let frame name data = "event: " ^ name ^ "\r\ndata: " ^ Yojson.Safe.to_string data ^ "\r\n\r\n"
let started = frame "started" (`Assoc ["integration_id",`String "codex";"login_id",`String session;"account_ref",`String account])
let complete = frame "complete" (`Assoc ["integration_id",`String "codex";"account_ref",`String account;
  "authentication",`String "authenticated";"invocation_verified",`Bool false])
let inventory = `Assoc ["setup_revision",`String "revision";"default_runtime_selection", `List [`String "primary"; `String "fallback"];
  "account_emails",`List [];
  "runtimes",`List [`Assoc ["id",`String "unrelated"];`Assoc ["id",`String "fallback"];`Assoc ["id",`String "primary"]];
  "integrations",`List (List.map (fun (id,protocol) -> `Assoc ["id",`String id;"display_name",`String id;"protocol",`String protocol;"origin",`String "runtime_config"])
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
    check bool "requested client selected" true (Login.focused_client t=Some client))
    ["codex",Login.Codex;"claude",Login.Claude;"muse",Login.Muse;"antigravity",Login.Antigravity];
  let unknown=Login.create "not-a-client" in
  check bool "unknown client refused" true (Result.is_error (Login.inventory unknown inventory));
  let t=Login.create "codex" in ok (Login.inventory t inventory);t.provider<-Some provider;t.account_ref<-Some account;
  let body=Login.save_body t [model 0] in
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
  check bool "render masks private input" false (List.exists (fun line -> line="private-code" || String.ends_with ~suffix:"private-code" line) (List.map Login.row_text (Login.lines t)));
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
  (* 12 cells wrap the notice over several rows; the cursor row still shows. *)
  List.iter (fun (width, cursor) -> t.cursor<-cursor;
    check bool "selected model visible in short viewport" true
      (List.mem ("> [ ] model " ^ string_of_int cursor) (List.map Login.row_text (Login.visible_lines ~height:6 ~width t))))
    [80,0; 80,15; 80,29; 12,0; 12,15; 12,29];
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
  let t=Login.create "codex" in ok (Login.inventory t inventory);
  let finished refresh_failed=Login.Finished {saved=Login.Saved_verified; activation=Login.Active {exact_output_available=true}; refresh_failed} in
  t.phase<-finished false;
  Login.refresh_saved t Login.Saved_verified (Error "network unavailable");
  check bool "transport failure cannot revoke verified save" true (t.phase=finished true);
  check bool "retry refreshes inventory instead of old login receipt" true (Login.key t "r"=Login.Refresh_saved Login.Saved_verified);
  Login.refresh_saved t Login.Saved_verified (Ok (`Assoc []));
  check bool "bad inventory cannot revoke verified save" true (t.phase=finished true);
  Login.refresh_saved t Login.Saved_verified (Ok inventory);
  check bool "successful refresh retains saved screen" true (t.phase=finished false)
let saved_activation_retry () =
  let t=Login.create "codex" in ok (Login.inventory t inventory);
  let saved = match Login.saved t (`Assoc ["configured", `Bool true; "readiness", `String "verified";
      "commit", `Assoc ["durability", `String "durable"; "warnings", `List []]]) with
    | Ok saved -> saved | Error message -> fail message in
  check bool "pending activation cannot dispatch another save" true (Login.key t "enter"=Login.Nothing);
  check bool "pending activation cannot duplicate activation" true (Login.key t "r"=Login.Nothing);
  List.iter (fun response ->
    check bool "unconfirmed activation is not active" false (Login.activated t saved response);
    check bool "retry activates without another save" true (Login.key t "r"=Login.Activate_saved saved);
    Login.refresh_saved t saved (Ok inventory);
    check bool "inventory cannot turn saved configuration into active runtime" true
      (Login.key t "enter"=Login.Activate_saved saved))
    [Error "private configuration detail";
     Ok (`Assoc ["runtime_ready", `Bool true; "model_setup", `Assoc ["status", `String "available"]]);
     Ok (`Assoc ["runtime_ready", `Bool true; "exact_output_authority_available", `Bool true;
                "model_setup", `Assoc ["status", `String "waiting"]])];
  check bool "chat runtime can activate before exact output becomes available" true
    (Login.activated t saved (Ok (`Assoc ["runtime_ready", `Bool true;
      "exact_output_authority_available", `Bool false; "model_setup", `Assoc ["status", `String "available"]])));
  Login.refresh_saved t saved (Error "inventory unavailable");
  check bool "active result survives a failed inventory refresh" true
    (t.phase=Login.Finished {saved; activation=Login.Active {exact_output_available=false}; refresh_failed=true});
  check bool "active refresh is read-only" true (Login.key t "r"=Login.Refresh_saved saved)
let closed_activation_recovery () =
  let t=Login.create "codex" in ok (Login.inventory t inventory);
  t.provider <- Some provider;
  let saved = Login.Saved_partly {unverified=[]; not_rechecked=["saved-account.model"]} in
  Login.activating t saved;
  t.generation <- 7;
  check bool "closing retains a pending activation" true (Login.activation_incomplete t);
  let reopened = match Login.reopen_saved ~requested:"" t with
    | Some view -> view | None -> fail "saved activation disappeared on reopen" in
  check bool "the pending request keeps the same view identity" true (reopened == t);
  check int "reopening does not supersede the pending reply" 7 reopened.generation;
  check bool "reopening cannot start a duplicate activation" true (Login.key reopened "r"=Login.Nothing);
  check bool "another client cannot claim the saved account" true
    (Login.reopen_saved ~requested:"claude" t=None);
  ignore (Login.activated t saved (Error "lost response"));
  check bool "closing retains an unconfirmed activation" true (Login.activation_incomplete t);
  let reopened = match Login.reopen_saved ~requested:"codex" t with
    | Some view -> view | None -> fail "failed activation disappeared on reopen" in
  Login.refresh_saved reopened saved (Error "inventory unavailable");
  check bool "reopened failed activation retries only resume with the original receipt" true
    (Login.key reopened "enter"=Login.Activate_saved saved);
  ignore (Login.activated t saved (Ok (`Assoc ["runtime_ready",`Bool true;
    "exact_output_authority_available",`Bool true;"model_setup",`Assoc ["status",`String "available"]])));
  check bool "a detached request can finish before reopening" true
    (Option.is_some (Login.reopen_saved ~requested:"codex" t));
  check bool "completed activation does not need retaining on another close" false (Login.activation_incomplete t);
  check bool "the completed receipt refreshes without repeating activation" true (Login.key t "r"=Login.Refresh_saved saved)
let closed_activation_accounts () =
  let first=Login.create "codex" and second=Login.create "codex" in
  first.provider <- Some {provider with id="codex_first"};
  second.provider <- Some {provider with id="codex_second"};
  first.providers <- [{provider with id="codex";origin=Login.Catalog};
    {provider with id="codex_first";origin=Login.Configured}];
  second.providers <- first.providers @ [{provider with id="codex_second";origin=Login.Configured}];
  let saved_first=Login.Saved_partly {unverified=[]; not_rechecked=["first.model"]} in
  let saved_second=Login.Saved_unverified ({runtime_id="second.model";code="quota_exhausted"},[]) in
  Login.activating first saved_first;
  Login.activating second saved_second;
  ignore (Login.activated first saved_first (Error "first unavailable"));
  ignore (Login.activated second saved_second (Error "second unavailable"));
  check bool "catalog codex entry does not shadow client recovery" true
    (Option.is_some (Login.reopen_saved ~requested:"codex" first));
  first.providers <- {provider with id="codex";origin=Login.Configured} :: first.providers;
  check bool "an explicit configured codex ID still wins over the client alias" true
    (Login.reopen_saved ~requested:"codex" first=None);
  let retained = Login.retain_activation first [] |> Login.retain_activation second in
  let retained = Login.retain_activation second retained in
  check int "closing another account preserves both distinct receipts" 2 (List.length retained);
  let taken, rest = Login.take_saved ~requested:"codex_first" retained in
  let first = match taken with Some view -> view | None -> fail "first account receipt lost" in
  check bool "first account retries its own saved receipt" true (Login.key first "r"=Login.Activate_saved saved_first);
  check int "reopening one account leaves the other recoverable" 1 (List.length rest);
  let taken, rest = Login.take_saved ~requested:"codex_second" rest in
  let second = match taken with Some view -> view | None -> fail "second account receipt lost" in
  check bool "second account keeps its usage-limited receipt" true (Login.key second "enter"=Login.Activate_saved saved_second);
  check int "reopened views are removed once" 0 (List.length rest)
let generated_account_activation_recovery () =
  let catalog={provider with origin=Login.Catalog} in
  let inventory runtimes = `Assoc ["setup_revision",`String "saved-revision";
    "default_runtime_selection",`List [`String "old.selected"];"account_emails",`List [];
    "runtimes",`List (List.map (fun (id,owner) -> `Assoc ["id",`String id;"provider_id",`String owner]) runtimes);
    "integrations",`List (List.map (fun id -> `Assoc ["id",`String id;"display_name",`String id;
      "protocol",`String "codex-app-server";"origin",`String (if id="codex" then "masc_integration" else "runtime_config")])
      ["codex";"old-account";"generated-first";"generated-second"])] in
  let runtimes=["old.selected","old-account";"first.runtime","generated-first";"second.runtime","generated-second"] in
  let make id =
    let t=Login.create "codex" in
    ignore (Login.begin_attempt t catalog ~existing:false);
    t.existing <- ["old.selected"];
    let saved=ok (Login.saved t (`Assoc ["configured",`Bool true;"readiness",`String "verified";
      "commit",`Assoc ["durability",`String "durable";"warnings",`List []];
      "runtime_ids",`List [`String "old.selected";`String id]])) in
    ignore (Login.activated t saved (Error "activation unavailable"));
    t,saved in
  let first,saved_first=make "first.runtime" and second,saved_second=make "second.runtime" in
  Login.refresh_saved first saved_first (Ok (inventory runtimes));
  Login.refresh_saved second saved_second (Ok (inventory runtimes));
  check (option string) "new account reconciles from explicit runtime ownership"
    (Some "generated-first") (Option.map (fun (p:Login.provider)->p.id) first.provider);
  let retained=Login.retain_activation first [] |> Login.retain_activation second in
  let chosen,retained=Login.take_saved ~requested:"generated-first" retained in
  check bool "generated account ID selects its own saved receipt" true
    (match chosen with Some view -> view==first && Login.key view "r"=Login.Activate_saved saved_first | None -> false);
  let chosen,_=Login.take_saved ~requested:"generated-second" retained in
  check bool "second same-client receipt remains independently recoverable" true
    (match chosen with Some view -> view==second && Login.key view "enter"=Login.Activate_saved saved_second | None -> false);
  Login.refresh_saved first saved_first (Error "refresh failed");
  check bool "later read failure retains established configured account" true
    (Option.is_some (Login.reopen_saved ~requested:"generated-first" first));
  let missing,saved=make "absent.runtime" in
  Login.refresh_saved missing saved (Ok (inventory runtimes));
  check bool "missing ownership never adopts another account" true (missing.provider=Some catalog);
  let ambiguous,saved=make "first.runtime" in
  Login.refresh_saved ambiguous saved (Ok (inventory (("first.runtime","generated-second")::runtimes)));
  check bool "ambiguous ownership never picks the first account" true (ambiguous.provider=Some catalog);
  ignore (Login.begin_attempt first catalog ~existing:false);
  check (list string) "a new login cannot reuse a previous save's runtime ownership" [] first.saved_runtime_ids

let failed_activation_blocks_login_shortcuts () =
  let t=Login.create "codex" in t.provider <- Some provider;
  let saved=Login.Saved_partly {unverified=[];not_rechecked=["saved.model"]} in
  ignore (Login.activated t saved (Error "activation unavailable"));
  let original=t.phase in
  List.iter (fun key ->
    check bool ("failed activation blocks "^key) true (Login.key t key=Login.Nothing);
    check bool "blocked login preserves saved phase" true (t.phase=original)) ["n";"e"];
  check bool "activation-only retry remains available" true (Login.key t "r"=Login.Activate_saved saved);
  check bool "close remains available for detached recovery" true (Login.key t "esc"=Login.Close);
  ignore (Login.activated t saved (Ok (`Assoc ["runtime_ready",`Bool true;
    "exact_output_authority_available",`Bool true;"model_setup",`Assoc ["status",`String "available"]])));
  check bool "new login is available after confirmed activation" true
    (Login.key t "n"=Login.Start {provider;existing=false})

let missing_model_context () =
  List.iter (fun client ->
    let t=Login.create "" in let unknown={ (model 0) with context=None } in
    t.provider<-Some {provider with client};t.phase<-Login.Models;t.models<-[unknown];
    let action=Login.key t " " in
    match client with
    | Login.Antigravity -> check bool "native observation available" true (action=Login.Prepare unknown)
    | Login.Muse ->
      check bool "unreported Muse context is not invented" true (action=Login.Nothing && t.phase=Login.Models);
      check bool "Muse can refresh native metadata" true (Login.key t "r"=Login.Discover)
    | Login.Codex | Login.Claude ->
      check bool "explicit documented limit requested" true (action=Login.Nothing && t.phase=Login.Documented_context unknown);
      check bool "empty context cannot save" true (Login.key t "\r"=Login.Nothing);
      Login.paste t "32768";
      check bool "documented context returns to model selection" true
        (Login.key t "\r"=Login.Nothing && t.phase=Login.Models);
      (match Login.key t "\r" with
       | Login.Save [selected] -> check (option int) "operator documented value still goes through save verification" (Some 32768) selected.context
       | _ -> fail "documented context did not reach verification"))
    [Login.Codex;Login.Claude;Login.Antigravity;Login.Muse]
let named_default_identity () =
  let fields=match inventory with `Assoc fields -> List.remove_assoc "default_runtime_id" fields | _ -> [] in
  let t=Login.create "codex" in
  ok (Login.inventory t (`Assoc (("default_runtime_id",`String "named-lane") :: fields)));
  t.provider<-Some provider;t.account_ref<-Some account;
  let body=Login.save_body t [model 0] in
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
  let selected={ (model 1) with context=Some 65536 } in
  t.models<-[model 0;selected];t.selected_models<-[selected.id];t.cursor<-1;t.phase<-Login.Saving;
  Login.save_failed t "save refused";
  check bool "save failure leads with the request's own reason" true (String.starts_with ~prefix:"save refused" t.notice);
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
  | Login.Save [chosen] ->
    check string "same model retained" selected.id chosen.id;
    check (option int) "documented context survives failed save" selected.context chosen.context;
    let body=Login.save_body t [chosen] in
    let open Yojson.Safe.Util in
    check string "retry uses new revision" "new-revision" (body |> member "revision" |> to_string);
    check string "retry preserves new default" "new-default" (body |> member "default_runtime_id" |> to_string);
    check (list string) "retry uses current selection" ["fallback"] t.existing;
    check string "retry uses same account" account
      (body |> member "connections" |> to_list |> List.hd |> member "source" |> member "account_ref" |> to_string)
  | _ -> fail "refreshed save was not offered"
module Sgr_text = Masc_tui_sgr_text
module Sgr = Masc_tui_theme.Sgr
let contains text part =
  let n = String.length part in
  let rec at i = i + n <= String.length text && (String.sub text i n = part || at (i + 1)) in
  n = 0 || at 0
(* A runtime the provider declined for the account's usage is published
   unmeasured. The screen says so and names each such runtime on its own row,
   so a long runtime id is never cut behind the notice, and re-reading the
   list keeps that account instead of reporting a verified save. *)
let uncertain_durability_save () =
  let receipt durability = `Assoc ["configured",`Bool true; "readiness",`String "verified";
    "commit",`Assoc ["durability",durability;"warnings",`List []]] in
  let t=Login.create "codex" in
  let saved=match Login.saved t (receipt (`String "unconfirmed")) with
    | Ok saved -> saved | Error detail -> fail detail in
  check bool "visible save retains uncertain durability" true
    (saved=Login.Saved_durability_unconfirmed Login.Saved_verified);
  check bool "warning is visible" true (contains t.notice "내구성을 확인하지 못했습니다");
  Login.refresh_saved t saved (Error "offline");
  check bool "refresh failure keeps durability warning" true (contains t.notice "내구성을 확인하지 못했습니다");
  check bool "retry refreshes and does not save again" true (Login.key t "r"=Login.Refresh_saved saved);
  List.iter (fun unknown -> check bool "missing or unknown durability is not durable" true
    (Result.is_error (Login.saved (Login.create "codex") (receipt unknown))))
    [`Null; `String "unknown"; `Bool true]
let uncertain_lock_release_save () =
  let warning = `Assoc ["code",`String "runtime_config_lock_release_unconfirmed";
    "detail",`String "private-server-path"] in
  let receipt warnings = `Assoc ["configured",`Bool true;"readiness",`String "verified";
    "commit",`Assoc ["durability",`String "unconfirmed";"warnings",warnings]] in
  let t=Login.create "codex" in
  let saved=match Login.saved t (receipt (`List [warning])) with Ok saved -> saved | Error detail -> fail detail in
  check bool "both storage and lock uncertainty are retained" true
    (saved=Login.Saved_durability_unconfirmed (Login.Saved_lock_release_unconfirmed Login.Saved_verified));
  Login.refresh_saved t saved (Error "offline");
  let rows = Login.lines t |> List.map Login.row_text |> String.concat " " in
  check bool "lock warning is visible after refresh failure" true (contains rows "잠금 해제");
  check bool "backend diagnostic is not displayed" false (contains rows "private-server-path");
  check bool "r only retries the read" true (Login.key t "r"=Login.Refresh_saved saved);
  List.iter (fun warnings -> check bool "unknown warning cannot claim a clean save" true
    (Result.is_error (Login.saved (Login.create "codex") (receipt warnings))))
    [`Null;`List [`Assoc ["code",`String "unknown"]]]

let usage_limited_save () =
  let t=Login.create "codex" in ok (Login.inventory t inventory);
  let receipt ?(selected=["codex_1a2b3c4d.gpt-6-sol_1a2b3c4d"]) rows = `Assoc ["configured",`Bool true;"commit",`Assoc ["durability",`String "durable";"warnings",`List []];
    "readiness",`String "usage_limited";"runtime_ids",`List (List.map (fun id -> `String id) selected);"unverified",`List rows] in
  let row id code = `Assoc ["runtime_id",`String id;"code",`String code] in
  let saved = match Login.saved t (receipt [row "codex_1a2b3c4d.gpt-6-sol_1a2b3c4d" "quota_exhausted"]) with
    | Ok saved -> saved | Error message -> fail message in
  ignore (Login.activated t saved (Ok (`Assoc ["runtime_ready", `Bool true;
    "exact_output_authority_available", `Bool true; "model_setup", `Assoc ["status", `String "available"]])));
  let rows () = List.map Login.row_text (Login.lines t) in
  check bool "the unmeasured runtime and its code have their own row" true
    (List.mem "  codex_1a2b3c4d.gpt-6-sol_1a2b3c4d (quota_exhausted)" (rows ()));
  check bool "the save is not reported as verified" false (contains t.notice "검증하고 저장했습니다");
  check bool "retry keeps what the save published" true (Login.key t "r"=Login.Refresh_saved saved);
  Login.refresh_saved t saved (Error "network unavailable");
  check bool "a failed list read is its own row" true
    (List.mem "목록을 새로 읽지 못했습니다. r로 다시 확인하세요." (rows ()));
  Login.refresh_saved t saved (Ok inventory);
  check bool "a refreshed list keeps the unmeasured account" true
    (t.phase=Login.Finished {saved; activation=Login.Active {exact_output_available=true}; refresh_failed=false}
     && List.mem "  codex_1a2b3c4d.gpt-6-sol_1a2b3c4d (quota_exhausted)" (rows ()));
  List.iter (fun (name, json) ->
    check bool name true (Result.is_error (Login.saved (Login.create "codex") json)))
    [ "an empty unmeasured list is unreadable", receipt [];
      "an unmeasured row without a code is unreadable", receipt [`Assoc ["runtime_id",`String "codex_1a2b3c4d.gpt-6-sol_1a2b3c4d"]];
      "an unmeasured runtime the save did not select is unreadable", receipt ~selected:["other"] [row "codex_1a2b3c4d.gpt-6-sol_1a2b3c4d" "quota_exhausted"];
      "a verified receipt with an unmeasured list is unreadable",
        `Assoc ["configured",`Bool true;"commit",`Assoc ["durability",`String "durable";"warnings",`List []];"readiness",`String "verified";"unverified",`List [row "x" "rate_limited"]] ]
(* A save that left selected runtimes uncalled is neither verified nor
   usage-limited. The screen summarizes retained connections, and a receipt that
   claims verified beside a not_rechecked list is unreadable rather than shown
   as a full verification. *)
let partly_checked_save () =
  let t=Login.create "codex" in ok (Login.inventory t inventory);
  let kept = "codex_1a2b3c4d.gpt-6-sol_1a2b3c4d" and added = "codex_1a2b3c4d.gpt-6-luna_1a2b3c4d" in
  let receipt ?(readiness="partly_checked") ?(unverified=`List []) ?(rechecked=`List [`String kept]) () =
    `Assoc ["configured",`Bool true;"commit",`Assoc ["durability",`String "durable";"warnings",`List []];"readiness",`String readiness;
      "runtime_ids",`List [`String added;`String kept];"unverified",unverified;"not_rechecked",rechecked] in
  let saved = match Login.saved t (receipt ()) with
    | Ok saved -> saved | Error message -> fail message in
  ignore (Login.activated t saved (Ok (`Assoc ["runtime_ready", `Bool true;
    "exact_output_authority_available", `Bool true; "model_setup", `Assoc ["status", `String "available"]])));
  let rows () = List.map Login.row_text (Login.lines t) in
  check bool "retained runtime is explicitly not rechecked" true
    (List.mem ("  " ^ kept ^ " (이번 저장에서 재검증하지 않음)") (rows ()));
  check bool "the save is not reported as verified" false (contains t.notice "검증하고 저장했습니다");
  check bool "the notice says existing connections were retained" true (contains t.notice "기존 연결은 그대로 유지했습니다");
  check bool "retry keeps what the save published" true (Login.key t "r"=Login.Refresh_saved saved);
  let t2=Login.create "codex" in ok (Login.inventory t2 inventory);
  let saved2 = match Login.saved t2 (receipt ~unverified:(`List [`Assoc ["runtime_id",`String added;"code",`String "quota_exhausted"]]) ()) with
    | Ok saved -> saved | Error message -> fail message in
  ignore (Login.activated t2 saved2 (Ok (`Assoc ["runtime_ready", `Bool true;
    "exact_output_authority_available", `Bool true; "model_setup", `Assoc ["status", `String "available"]])));
  check bool "quota failure and not-rechecked runtime are separately listed" true
    (let r = List.map Login.row_text (Login.lines t2) in
     List.mem ("  " ^ added ^ " (quota_exhausted)") r && List.mem ("  " ^ kept ^ " (이번 저장에서 재검증하지 않음)") r);
  let visible () = Login.visible_lines ~height:2 ~width:32 t2 |> List.map Login.row_text in
  let initial = visible () in
  check bool "small result starts with its save notice" true
    (List.exists (fun row -> contains row "저장했습니다") initial);
  let expected = List.concat_map
      (Masc_tui_message_layout.wrap_words ~max_cells:32)
      [ "  " ^ added ^ " (quota_exhausted)";
        "  " ^ kept ^ " (이번 저장에서 재검증하지 않음)" ] in
  let seen = ref initial in
  List.iter (fun _ -> ignore (Login.key t2 "j"); seen := visible () @ !seen)
    (List.concat_map (Masc_tui_message_layout.wrap_words ~max_cells:32)
       (List.map Login.row_text (Login.lines t2)));
  List.iter (fun row -> check bool "every result fragment is reachable by scrolling" true
      (List.mem row !seen)) expected;
  let bottom = visible () in
  ignore (Login.key t2 "j"); ignore (Login.key t2 "j");
  ignore (Login.key t2 "k");
  check bool "coalesced down down up moves from the bottom" true (visible () <> bottom);
  ignore (Login.key t2 "j"); ignore (visible ());
  List.iter (fun _ -> ignore (Login.key t2 "j"); ignore (visible ())) expected;
  ignore (Login.key t2 "k");
  check bool "one up key moves after repeated down keys at the bottom" true
    (visible () <> bottom);
  List.iter (fun _ -> ignore (Login.key t2 "k"))
    (List.concat_map (Masc_tui_message_layout.wrap_words ~max_cells:32)
       (List.map Login.row_text (Login.lines t2)));
  check (list string) "scroll can return to the initial result" initial (visible ());
  List.iter (fun (name, json) ->
    check bool name true (Result.is_error (Login.saved (Login.create "codex") json)))
    [ "an empty not_rechecked list is unreadable", receipt ~rechecked:(`List []) ();
      "a not_rechecked runtime the save did not select is unreadable", receipt ~rechecked:(`List [`String "other"]) ();
      "a missing not_rechecked list is unreadable", receipt ~rechecked:`Null ();
      "a verified receipt with a not_rechecked list is unreadable", receipt ~readiness:"verified" ~unverified:`Null () ];
  List.iter (fun invalid ->
    let waiting=Login.create "codex" in
    let phase=waiting.phase and notice=waiting.notice in
    check bool "a malformed row beside a valid kept runtime rejects the entire receipt" true
      (Result.is_error (Login.saved waiting (receipt ~rechecked:(`List [`String kept; invalid]) ())));
    check bool "a rejected receipt cannot finish the save" true (waiting.phase=phase);
    check string "a rejected receipt cannot announce a saved configuration" notice waiting.notice)
    [`Int 17; `Null; `String ""; `Bool true; `Assoc []; `List []]
(* What the renderer draws for a row: the pane's own text sanitized, the
   client's text drawn with its colours. *)
let drawn row = match row with
  | Login.Text text -> Masc.Tui_terminal_text.sanitize_terminal_text text
  | Login.Terminal line -> Sgr_text.render ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text line
let styled code text = if String.length code = 0 then text else code ^ text ^ Sgr.reset
(* The Codex device login as it reached the pane on 2026-09-28 (the code is
   made up). Split inside an escape, the way a stream chunk can end. *)
let codex_device_login = String.concat "\n" [
  "Welcome to Codex [v\027[90m0.157.1\027[0m]";
  "\027[90mOpenAI's command-line coding agent\027[0m";
  "";
  "1. Open this link in your browser and sign in to your account";
  "   \027[94mhttps://auth.openai.com/codex/device\027[0m";
  "";
  "2. Enter this one-time code \027[90m(expires in 15 minutes)\027[0m";
  "   \027[94mABCD-EFGH\027[0m";
  "" ]
let official_client_colours () =
  let t = Login.create "codex" in
  ignore (Login.begin_attempt t provider ~existing:false);
  let feed chunk = ignore (Login.event ~generation:t.generation t (Login.Output chunk)) in
  let cut = String.length "Welcome to Codex [v\027[9" in
  feed (String.sub codex_device_login 0 cut);
  check bool "half an escape is not drawn while the rest is on its way" false
    (contains (String.concat "\n" (List.map drawn (Login.lines t))) "\\x1B");
  feed (String.sub codex_device_login cut (String.length codex_device_login - cut));
  let rows = Login.lines t in
  let screen = String.concat "\n" (List.map drawn rows) in
  check bool "no escape is spelled out as text" false (contains screen "\\x1B");
  check bool "the link keeps its words" true (List.mem "   https://auth.openai.com/codex/device" (List.map Login.row_text rows));
  check bool "the link is drawn in the client's blue" true
    (contains screen (styled Sgr.bright_blue "https://auth.openai.com/codex/device"));
  check bool "the one-time code is drawn in the client's blue" true (contains screen (styled Sgr.bright_blue "ABCD-EFGH"));
  check bool "the version is drawn in the client's grey" true (contains screen (styled Sgr.gray "0.157.1"));
  check bool "the pane's own prompt is still there" true (List.mem "로그인 코드: " (List.map Login.row_text rows))
let foreign_escapes_never_reach_the_terminal () =
  let only line = match Sgr_text.parse line with [ runs ] -> runs | lines -> fail (Printf.sprintf "%d lines" (List.length lines)) in
  let hostile = only "a\027[2J\027[5;5Hb\027]8;;https://evil.example/\027\\link\027]8;;\027\\c\027[?25ld\027(Be\027]0;title\007f\0277g" in
  check string "cursor moves, hyperlinks, titles and charsets are dropped, their text kept" "ablinkcdefg" (Sgr_text.text hostile);
  check bool "nothing the client wrote is sent as an escape" false
    (String.contains (Sgr_text.render ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text hostile) '\027');
  check string "a sequence the stream ends inside waits for the rest" "x" (Sgr_text.text (only "x\027[9"));
  check string "an ESC that starts nothing is shown, not sent" "a\\x1B\\x01b"
    (Sgr_text.render ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text (only "a\027\001b"));
  (match Sgr_text.parse "\027[31mred\nstill red\027[0m plain" with
   | [ _; [ carried; after ] ] ->
     check bool "a colour carries over the line end" true Sgr_text.(carried.pen.foreground = Some (Palette Red));
     check bool "reset ends it" true Sgr_text.(after.pen = plain)
   | _ -> fail "two lines expected");
  let channels = function
    | Some (Sgr_text.Rgb colour) ->
      Some Masc_tui_terminal_palette.(red colour, green colour, blue colour)
    | Some (Sgr_text.Palette _ | Sgr_text.Bright _) | None -> None in
  (match only "\027[38;5;196mX\027[48;5;1mY\027[38;2;10;20;30mZ\027[38:2::1:2:3mW" with
   | [ x; y; z; w ] ->
     let foreground (run : Sgr_text.run) = run.Sgr_text.pen.Sgr_text.foreground in
     check (option (triple int int int)) "38;5 cube index" (Some (255, 0, 0)) (channels (foreground x));
     check bool "a background's numbers are not read as codes" true
       (y.Sgr_text.pen.Sgr_text.weight = Sgr_text.Regular && foreground y = foreground x);
     check (option (triple int int int)) "38;2 truecolor" (Some (10, 20, 30)) (channels (foreground z));
     check (option (triple int int int)) "colon sub-parameters" (Some (1, 2, 3)) (channels (foreground w))
   | runs -> fail (Printf.sprintf "%d runs" (List.length runs)))
(* The server reads each account's email from its client's login file; each
   client's account list leads every row with it so the operator can tell
   accounts apart. *)
let account_emails_beside_providers () =
  let with_emails rows =
    let fields = match inventory with `Assoc fields -> List.remove_assoc "account_emails" fields | _ -> [] in
    `Assoc (("account_emails", `List rows) :: fields) in
  let row id state extra = `Assoc (["integration_id", `String id; "state", `String state] @ extra) in
  (* Each client's account rows, without the new-account row and the cursor. *)
  let account_rows json =
    List.map (fun requested ->
      let t = Login.create requested in
      ok (Login.inventory t json);
      List.filter_map (fun row ->
        let text = String.sub row 2 (String.length row - 2) in
        if String.equal text "+ 새 계정" then None else Some text)
        (List.map Login.row_text (List.tl (Login.lines t))))
      ["codex"; "claude"; "muse"; "antigravity"] in
  check (list (list string)) "each account row leads with its email or why not"
    [ ["operator@example.com  (codex)"]; ["이메일 모름: 로그인 파일을 못 읽음  (claude-code)"];
      ["이메일 모름: 로그인 파일 형식을 모름  (muse-code)"]; ["이메일 모름: 표시할 수 없는 값  (antigravity)"] ]
    (account_rows (with_emails [
      row "codex" "read" ["email", `String "operator@example.com"];
      row "claude-code" "not_read" ["cause", `String "source_unavailable"];
      row "muse-code" "not_read" ["cause", `String "source_unrecognized"];
      row "antigravity" "not_read" ["cause", `String "invalid_email"] ]));
  check (list (list string)) "an account with no email row draws its name alone"
    [ ["codex"]; ["이메일 없음: 환경 변수의 인증 정보로 실행  (claude-code)"];
      ["이메일 모름: 클라이언트가 알려 주지 않음  (muse-code)"]; ["antigravity"] ]
    (account_rows (with_emails [
      row "claude-code" "not_read" ["cause", `String "environment_credential"];
      row "muse-code" "not_read" ["cause", `String "not_reported"] ]));
  (* The email is display data: a row this TUI cannot read is shown as that
     row's own unreadable state, and the account list is never refused. *)
  let codex_row rows = List.hd (account_rows (with_emails rows)) in
  List.iter (fun (name, rows) ->
    check (list string) name ["이메일 정보를 알아볼 수 없음  (codex)"] (codex_row rows))
    [ "an unknown state is that row's own", [ row "codex" "verified" [] ];
      "read without an email", [ row "codex" "read" [] ];
      "an email beside a cause",
      [ row "codex" "not_read" ["cause", `String "not_reported"; "email", `String "x@example.com"] ];
      "an unknown cause", [ row "codex" "not_read" ["cause", `String "vanished"] ];
      "not read without a cause", [ row "codex" "not_read" [] ];
      "one account listed twice has no single state",
      [ row "codex" "read" ["email", `String "x@example.com"];
        row "codex" "not_read" ["cause", `String "not_reported"] ] ];
  check (list (list string)) "a bad row leaves the other rows readable"
    [ ["이메일 정보를 알아볼 수 없음  (codex)"]; ["operator@example.com  (claude-code)"]; ["muse-code"]; ["antigravity"] ]
    (account_rows (with_emails [ row "codex" "verified" []; row "claude-code" "read" ["email", `String "operator@example.com"] ]));
  let t = Login.create "" in
  ok (Login.inventory t (with_emails [ row "missing" "not_read" ["cause", `String "not_reported"]; `String "not a row" ]));
  check bool "rows for no listed integration are counted, not shown" true
    (String.ends_with ~suffix:" 어느 공급자 것인지 모르는 계정 이메일 2개는 보여 주지 않습니다." t.notice);
  check (list string) "the clients list each client once with its account count"
    [ "> Codex · 계정 1"; "  Claude Code · 계정 1"; "  Antigravity · 계정 1"; "  Muse · 계정 1" ]
    (List.map Login.row_text (List.tl (Login.lines t)));
  let fields = match inventory with `Assoc fields -> List.remove_assoc "account_emails" fields | _ -> [] in
  let t = Login.create "" in
  ok (Login.inventory t (`Assoc fields));
  check bool "an inventory without a readable email list still lists the clients" true
    (String.ends_with ~suffix:" 계정 이메일 목록은 읽지 못했습니다." t.notice
     && List.length (Login.lines t) = 5)

(* The Overview draws only the emails that were read, by integration id, and
   counts the rows it cannot read; a document with no readable list is an
   error it can say. *)
let emails_for_the_overview () =
  let row id state extra = `Assoc (["integration_id", `String id; "state", `String state] @ extra) in
  let document rows = `Assoc ["account_emails", `List rows] in
  check (result (pair (list (pair string string)) int) string)
    "read emails, and the rows this build cannot read"
    (Ok ([ "codex", "operator@example.com" ], 3))
    (Login.emails_of_document (document [
       row "codex" "read" ["email", `String "operator@example.com"];
       row "claude-code" "not_read" ["cause", `String "environment_credential"];
       row "muse-code" "verified" [];
       row "twice" "read" ["email", `String "a@example.com"];
       row "twice" "read" ["email", `String "b@example.com"];
       `String "not a row" ]));
  check bool "no readable list is an error" true
    (Result.is_error (Login.emails_of_document (`Assoc [])))

(* The server's row for every outcome, through the TUI's decoder: the
   hand-kept spellings on both sides stay in step. *)
let server_email_rows_round_trip () =
  let module Email = Runtime_account_email in
  let email = match Email.of_string "operator@example.com" with Some email -> email | None -> fail "fixture" in
  List.iter (fun (server, expected) ->
    let fields = match inventory with `Assoc fields -> List.remove_assoc "account_emails" fields | _ -> [] in
    let t = Login.create "" in
    ok (Login.inventory t
      (`Assoc (("account_emails", `List [ Email.row_json ~integration_id:"codex" server ]) :: fields)));
    let decoded = match t.Login.account_emails with
      | Login.Email_rows {rows; _} -> List.assoc_opt "codex" rows
      | Login.Email_list_unrecognized -> None in
    check bool "server row decodes to its own state" true (decoded = Some expected))
    [ Ok email, Login.Email "operator@example.com";
      Error Email.Source_unavailable, Login.Not_read Login.Login_file_unreadable;
      Error Email.Source_unrecognized, Login.Not_read Login.Login_file_unrecognized;
      Error Email.Not_reported, Login.Not_read Login.Email_not_reported;
      Error Email.Invalid_email, Login.Not_read Login.Email_not_displayable;
      Error Email.Environment_credential, Login.Not_read Login.Environment_credential ]

(* D on a provider asks what removing it changes; the answer is a question the
   operator confirms with Enter, and Esc goes back to the list, not out of /login. *)
let removal_preview_json ?(id="codex") state extra =
  `Assoc (["integration_id",`String id;"revision",`String "rev-1";"state",`String state] @ extra)
let removable = removal_preview_json "removable"
  ["changes",`List [`Assoc ["kind",`String "table";"path",`String "providers.codex"];
                    `Assoc ["kind",`String "lane_candidate";"lane",`String "coding";"runtime",`String "codex.gpt"];
                    `Assoc ["kind",`String "assignment";"keeper",`String "tester";"runtime",`String "codex.gpt"]];
   "login_store",`String "/home/op/.codex-two"]
let rows t = List.map Login.row_text (Login.lines t)
let mentions text t = List.exists (fun row ->
  let n=String.length text in let rec at i = i+n <= String.length row && (String.sub row i n = text || at (i+1)) in at 0) (rows t)
(* A refused save's reason ends in the verification code and detail, the part
   that says what to do; at 40 cells it is wrapped, not cut. *)
let a_long_reason_is_read_whole () =
  let t=Login.create "codex" in ok (Login.inventory t inventory);
  t.provider<-Some provider; t.models<-[model 0]; t.phase<-Login.Saving;
  Login.save_failed t
    "HTTP 502: Runtime \"codex.gpt\" did not pass response and tool verification (rate_limited)";
  let drawn = List.map Login.row_text (Login.visible_lines ~height:12 ~width:40 t) in
  check bool "every row fits" true
    (List.for_all (fun row -> Masc_tui_message_layout.display_width row <= 40) drawn);
  check bool "the code and the way back are on screen" true
    (let joined = String.concat " " drawn in contains joined "(rate_limited)" && contains joined "다시 저장하세요.")
let removal_from_the_list () =
  let t=Login.create "codex" in ok (Login.inventory t inventory);
  (match Login.key t "D" with
   | Login.Preview_removal {provider=p; refused=None} -> check string "the provider under the cursor" "codex" p.id
   | _ -> fail "D did not ask for a removal preview");
  ok (Login.removal_preview t provider ~refused:None removable);
  List.iter (fun text -> check bool ("shows " ^ text) true (mentions text t))
    ["[providers.codex]"; "lane coding"; "keeper tester"; "/home/op/.codex-two"];
  (match Login.key t "\r" with
   | Login.Remove {provider=p; revision; login_store} ->
     check string "the account" "codex" p.id; check string "the revision the preview read" "rev-1" revision;
     check (option string) "the login store for the notice" (Some "/home/op/.codex-two") login_store
   | _ -> fail "Enter did not remove");
  check bool "Esc goes back to the account's list" true
    (Login.key t "esc"=Login.Nothing && t.phase=Login.Providers (Login.Accounts Login.Codex))
(* The list opens on the clients. Choosing one lists a row that adds an
   account, then its accounts; Esc walks back out. A row whose origin this
   TUI does not know is not listed. *)
let clients_then_accounts () =
  let row id protocol origin =
    `Assoc ["id",`String id;"display_name",`String id;"protocol",`String protocol;"origin",`String origin] in
  let fields = match inventory with `Assoc fields -> List.remove_assoc "integrations" fields | _ -> [] in
  let json = `Assoc (("integrations",`List [
      row "codex" "codex-app-server" "masc_integration";
      row "codex_one" "codex-app-server" "runtime_config";
      row "codex_two" "codex-app-server" "runtime_config";
      row "claude-code" "claude-code" "masc_integration";
      row "codex_mystery" "codex-app-server" "somewhere_else" ]) :: fields) in
  let rows t = List.map Login.row_text (List.tl (Login.lines t)) in
  let t = Login.create "" in ok (Login.inventory t json);
  check (list string) "one row per client; a catalog entry is not an account"
    ["> Codex · 계정 2"; "  Claude Code"] (rows t);
  check bool "Enter opens the client's accounts" true (Login.key t "\r" = Login.Nothing);
  check (list string) "a new-account row, then the accounts"
    ["> + 새 계정"; "  codex_one"; "  codex_two"] (rows t);
  (match Login.key t "\r" with
   | Login.Start {provider; existing = false} -> check string "a new account goes through the catalog entry" "codex" provider.id
   | _ -> fail "Enter on + 새 계정 did not start a new login");
  ignore (Login.key t "j");
  (match Login.key t "\r" with
   | Login.Select_existing provider -> check string "Enter opens the account without login" "codex_one" provider.id
   | _ -> fail "Enter on an account did not select its existing credential");
  (match Login.key t "e" with
   | Login.Start {provider; existing = true} -> check string "e still explicitly reauthenticates" "codex_one" provider.id
   | _ -> fail "e on an account did not start its login");
  (match Login.key t "n" with
   | Login.Start {provider; existing = false} -> check string "n adds a new account from any row" "codex" provider.id
   | _ -> fail "n did not start a new login");
  (match Login.key t "D" with
   | Login.Preview_removal {provider; _} -> check string "D previews the account under the cursor" "codex_one" provider.id
   | _ -> fail "D did not preview the account");
  ignore (Login.key t "k");
  check bool "the new-account row cannot be removed" true (Login.key t "D" = Login.Nothing);
  check bool "Esc goes back to the clients, on the same client" true
    (Login.key t "esc" = Login.Nothing && t.phase = Login.Providers Login.Clients && t.cursor = 0);
  check bool "Esc on the clients closes" true (Login.key t "esc" = Login.Close);
  let t = Login.create "codex_two" in ok (Login.inventory t json);
  check (list string) "/login <account> opens its client on that account"
    ["  + 새 계정"; "  codex_one"; "> codex_two"] (rows t)
(* The server leaves a client's catalog entry out when runtime.toml declares a
   provider with the same id. The new-account row is still there and logs in
   through one of the client's accounts, without its account reference. *)
let a_client_without_a_catalog_entry () =
  let t=Login.create "codex" in ok (Login.inventory t inventory);
  check (list string) "the new-account row, then the account"
    ["  + 새 계정"; "> codex"] (List.map Login.row_text (List.tl (Login.lines t)));
  (match Login.key t "n" with
   | Login.Start {provider; existing = false} -> check string "n logs in a new account through the account's row" "codex" provider.id
   | _ -> fail "n did not start a new login");
  ignore (Login.key t "k");
  (match Login.key t "\r" with
   | Login.Start {provider; existing = false} -> check string "so does Enter on + 새 계정" "codex" provider.id
   | _ -> fail "Enter on + 새 계정 did not start a new login")
(* What /login asked for only decides where the list first opens: a later
   read keeps its view even once the requested account is gone, and r reads
   the list again on the view it was on. *)
let a_later_read_keeps_its_view () =
  let row id origin =
    `Assoc ["id",`String id;"display_name",`String id;"protocol",`String "codex-app-server";"origin",`String origin] in
  let fields = match inventory with `Assoc fields -> List.remove_assoc "integrations" fields | _ -> [] in
  let listing rows = `Assoc (("integrations",`List rows) :: fields) in
  let t=Login.create "codex_two" in
  ok (Login.inventory t (listing [row "codex" "masc_integration"; row "codex_two" "runtime_config"]));
  check bool "r reads the list again on the same view" true (Login.key t "r" = Login.Refresh_list (Login.Accounts Login.Codex));
  let without = listing [row "codex" "masc_integration"] in
  check bool "a first read that cannot find the request refuses" true
    (Result.is_error (Login.inventory (Login.create "codex_two") without));
  ok (Login.inventory ~view:(Login.Accounts Login.Codex) t without);
  check bool "a read after the removal stays on the client's accounts" true
    (t.phase = Login.Providers (Login.Accounts Login.Codex))
(* A pending login is offered back only for what /login asked for. *)
let a_pending_login_belongs_to_the_request () =
  let provider id origin : Login.provider = {id; label=id; client=Login.Codex; origin;enabled=true;setup_supported=true} in
  let one = provider "codex_one" Login.Configured and two = provider "codex_two" Login.Configured
  and catalog = provider "codex" Login.Catalog in
  let asked requested = let t = Login.create requested in t.providers <- [catalog; one; two]; t in
  check bool "a bare /login takes any row" true (Login.requested_matches (asked "") two);
  check bool "/login <id> takes that row" true (Login.requested_matches (asked "codex_two") two);
  check bool "/login <id> refuses another account" false (Login.requested_matches (asked "codex_one") two);
  check bool "/login <client> takes the client's rows" true
    (Login.requested_matches (let t = asked "codex" in t.providers <- [one; two]; t) two);
  check bool "a client name that is also a row's id is that row" false (Login.requested_matches (asked "codex") two)
(* With no account chosen, n and e say what to do instead of doing nothing. *)
let no_account_to_log_in () =
  let t=Login.create "" in t.phase<-Login.Failed;
  check bool "n asks for the list first" true (Login.key t "n" = Login.Nothing && contains t.notice "다시 읽은 뒤");
  t.notice <- "";
  check bool "so does e" true (Login.key t "e" = Login.Nothing && contains t.notice "다시 읽은 뒤")
let refused_removal () =
  let t=Login.create "codex" in ok (Login.inventory t inventory);
  ok (Login.removal_preview t provider ~refused:(Some "runtime.toml changed")
        (removal_preview_json "refused" ["reason",`String "[runtime].default is codex.gpt"]));
  check bool "the reason is shown" true (mentions "[runtime].default is codex.gpt" t);
  check bool "with why the preview was read again" true (String.length t.notice > 0 && mentions "runtime.toml changed" t);
  check bool "Enter does not remove a refused account" true (Login.key t "\r"=Login.Nothing);
  check bool "an answer for another account is refused" true
    (Result.is_error (Login.removal_preview t provider ~refused:None (removal_preview_json ~id:"claude-code" "refused" ["reason",`String "x"])));
  check bool "an unknown change is refused" true
    (Result.is_error (Login.removal_preview t provider ~refused:None
      (removal_preview_json "removable" ["changes",`List [`Assoc ["kind",`String "mystery"]];"login_store",`Null])))
let multi_model_selection () =
  let t=Login.create "codex" in
  ok (Login.inventory t inventory);
  t.provider<-Some provider; t.account_ref<-Some account;
  let catalog=`Assoc ["models",`List [
    `Assoc ["id",`String "first";"label",`String "First";"context",`Int 32768;"tools",`Bool true;"bound",`Bool false];
    `Assoc ["id",`String "blocked";"label",`String "Blocked";"context",`Int 32768;"tools",`Bool false;"bound",`Bool false];
    `Assoc ["id",`String "second";"label",`String "Second";"context",`Int 65536;"tools",`Bool true;"bound",`Bool false]]] in
  ok (Login.models t catalog);
  check (list string) "usable models start selected in catalog order"
    ["first";"second"] (List.map (fun (m:Login.model) -> m.id)
      (List.filter (fun (m:Login.model) -> List.mem m.id t.selected_models) t.models));
  check bool "unsupported model gives its reason" true (mentions "Blocked · 도구 호출 미지원" t);
  (match Login.key t "\r" with
   | Login.Save selected ->
     check (list string) "Enter submits all selected models in screen order"
       ["first";"second"] (List.map (fun (m:Login.model) -> m.id) selected);
     let body=Login.save_body t selected in
     let open Yojson.Safe.Util in
     check (list string) "one connection carries both models in order" ["first";"second"]
       (body |> member "connections" |> to_list |> List.hd |> member "models"
        |> to_list |> List.map (fun row -> row |> member "id" |> to_string));
     check bool "selection uses model indexes after existing defaults" true
       (body |> member "selection" |> to_list =
         [`Assoc ["runtime_id",`String "primary"];
          `Assoc ["runtime_id",`String "fallback"];
          `Assoc ["connection",`Int 0;"model",`Int 0];
          `Assoc ["connection",`Int 0;"model",`Int 1]])
   | _ -> fail "Enter did not submit both models");
  t.cursor<-1; ignore (Login.key t " ");
  check bool "unsupported model remains unselected" false (List.mem "blocked" t.selected_models);
  ignore (Login.key t "a");
  check (list string) "a clears all usable selections" [] t.selected_models;
  ignore (Login.key t "a");
  check (list string) "a restores both usable selections" ["first";"second"]
    (List.map (fun (m:Login.model) -> m.id)
       (List.filter (fun (m:Login.model) -> List.mem m.id t.selected_models) t.models));
  t.cursor<-0; ignore (Login.key t " ");
  check bool "Space toggles just the focused model" true
    (t.selected_models=["second"])

let already_bound_model_is_not_offered () =
  let fields=match inventory with `Assoc fields ->
    List.remove_assoc "runtimes" (List.remove_assoc "integrations" fields) | _ -> [] in
  let integration id = `Assoc ["id",`String id;"display_name",`String "Codex account";
    "protocol",`String "codex-app-server";"origin",`String "runtime_config"] in
  let rows=`List [
    `Assoc ["id",`String "primary"];
    `Assoc ["id",`String "fallback"];
    `Assoc ["id",`String "runtime-a";"provider_id",`String "codex_hA";"model",`String "first"];
    `Assoc ["id",`String "runtime-b";"provider_id",`String "codex_hB";"model",`String "second"]] in
  let inventory=`Assoc (("runtimes",rows)::("integrations",`List [integration "codex_hA";integration "codex_hB"])::fields) in
  List.iter (fun selected_provider ->
    let t=Login.create "codex" in
    ok (Login.inventory t inventory);
    check bool "invalid account selection is refused" true
      (Result.is_error (Login.selected_account t selected_provider (`Assoc ["account_ref",`String "bad"])));
    ok (Login.selected_account t selected_provider (`Assoc ["account_ref",`String account]));
    check bool "selected account is reused without login" true
      (t.account_ref=Some account && t.login_id=None && t.provider=Some selected_provider);
    let catalog=`Assoc ["models",`List [
      `Assoc ["id",`String "first";"context",`Int 32768;"tools",`Bool true;"bound",`Bool true];
      `Assoc ["id",`String "second";"context",`Int 32768;"tools",`Bool true;"bound",`Bool true];
      `Assoc ["id",`String "third";"context",`Int 32768;"tools",`Bool true;"bound",`Bool false]]] in
    ok (Login.models t catalog);
    check (list string) ("bound models remain visible for " ^ selected_provider.id)
      ["third"; "first"; "second"] (List.map (fun (m:Login.model) -> m.id) t.models);
    check (list string) "only the new model is selected" ["third"] t.selected_models;
    check bool "connected model is labelled" true
      (List.exists (fun row -> contains (Login.row_text row) "[연결됨] first") (Login.lines t));
    ignore (Login.key t "j"); ignore (Login.key t " ");
    check (list string) "connected model cannot be selected" ["third"] t.selected_models;
    ignore (Login.key t "a"); ignore (Login.key t "a");
    check (list string) "select all excludes connected models" ["third"] t.selected_models;
    check (list string) "save submits only the new model" ["third"]
      (match Login.key t "enter" with
       | Login.Save models -> List.map (fun (m:Login.model) -> m.id) models
       | _ -> fail "expected Save"))
    [{provider with id="codex_hA"};{provider with id="codex_hB"}]

let grouped_existing_accounts () =
  let provider id = `Assoc ["id", `String id; "display_name", `String ("Model provider " ^ id);
    "protocol", `String "codex-app-server"; "origin", `String "runtime_config"] in
  let ids ids = `List (List.map (fun id -> `String id) ids) in
  let group id providers runtimes = `Assoc ["id", `String id;
    "integration_ids", ids providers; "runtime_ids", ids runtimes] in
  let inventory = `Assoc ["setup_revision", `String "grouped"; "default_runtime_selection", `List [];
    "runtimes", `List (List.map (fun id -> `Assoc ["id", `String id]) ["a1.luna";"a2.luna-wide";"b.luna"]);
    "integrations", `List [provider "a1"; provider "a2"; provider "b"];
    "account_emails", `List [];
    "account_groups", `List [group "first-account" ["a1";"a2"] ["a1.luna";"a2.luna-wide"];
      group "second-account" ["b"] ["b.luna"]]] in
  let t=Login.create "" in
  ok (Login.inventory t inventory);
  check bool "two homes display as two accounts" true
    (List.exists (fun row -> contains (Login.row_text row) "계정 2") (Login.lines t));
  let t=Login.create "a2" in
  ok (Login.inventory t inventory);
  check int "requested nonrepresentative provider selects its account group" 1 t.cursor;
  check bool "group selects an actual provider for model discovery" true
    (match Login.key t "enter" with Login.Select_existing provider -> provider.id="a1" | _ -> false);
  check bool "D opens a member chooser, never a partial account deletion" true (Login.key t "D"=Login.Nothing);
  check bool "member chooser lists both original providers" true
    (match t.phase with Login.Providers (Login.Account_providers (Codex, ["a1";"a2"])) -> true | _ -> false);
  ignore (Login.key t "down");
  check bool "removal preview targets the explicitly selected provider only" true
    (match Login.key t "enter" with Login.Preview_removal {provider;_} -> provider.id="a2" | _ -> false);
  let selected = match Login.key t "enter" with
    | Login.Preview_removal {provider;_} -> provider
    | _ -> fail "expected selected connection preview" in
  let preview = match removable with
    | `Assoc fields -> `Assoc (("integration_id", `String selected.id) :: List.remove_assoc "integration_id" fields)
    | _ -> assert false in
  ok (Login.removal_preview t selected ~refused:None preview);
  check bool "confirmation names the selected connection" true
    (mentions "지울 공급자 연결: a2" t);
  check bool "confirmation does not claim account deletion" false (mentions "지울 계정:" t);
  let completion = Login.removed_notice selected None in
  check bool "completion names selected connection" true (contains completion "연결 (a2)");
  check bool "completion does not claim the account was deleted" false (contains completion "계정을 지웠습니다");
  ignore (Login.key t "esc");
  check bool "Esc returns to grouped account list" true
    (t.phase=Login.Providers (Login.Accounts Codex));
  let invalid = match inventory with
    | `Assoc fields -> `Assoc (("account_groups", `List [group "bad" ["missing"] []]) :: List.remove_assoc "account_groups" fields)
    | _ -> assert false in
  check bool "unknown grouping member cannot redirect account selection" true
    (Result.is_error (Login.inventory t invalid));
  let update name value = match inventory with
    | `Assoc fields -> `Assoc ((name,value) :: List.remove_assoc name fields)
    | _ -> assert false in
  let availability id enabled supported = match provider id with
    | `Assoc fields -> `Assoc (("enabled",`Bool enabled) ::
        ("setup_support",`String (if supported then "new_connection" else "unsupported")) :: fields)
    | _ -> assert false in
  List.iter (fun unavailable ->
    let changed = update "integrations" (`List [unavailable;availability "a2" true true;provider "b"]) in
    ok (Login.inventory t changed);
    check bool "usable member represents the account despite disabled or unsupported first member" true
      (match Login.key t "enter" with Login.Select_existing provider -> provider.id="a2" | _ -> false))
    [availability "a1" false true;availability "a1" true false];
  let disabled = update "integrations" (`List [availability "a1" false true;availability "a2" false true;provider "b"]) in
  ok (Login.inventory t disabled);
  check bool "an entirely disabled account cannot start model discovery" true (Login.key t "enter"=Login.Nothing);
  ok (Login.inventory t inventory);
  ignore (Login.key t "D");
  let changed = update "account_groups" (`List [group "rejoined" ["a1";"b"] [];
    group "separated" ["a2"] []]) in
  ok (Login.inventory ~view:(Login.Account_providers (Codex,["a1";"a2"])) t changed);
  check bool "refresh returns to fresh account membership instead of stale deletion IDs" true
    (t.phase=Login.Providers (Login.Accounts Codex));
  ignore (Login.key t "down"); ignore (Login.key t "D");
  check bool "reopening removal uses newly joined and excludes departed members" true
    (t.phase=Login.Providers (Login.Account_providers (Codex,["a1";"b"])))

let () = run "TUI account login" ["workflow",[
  test_case "existing providers group by native account without partial deletion" `Quick grouped_existing_accounts;
  test_case "multi-model selection submits ordered models" `Quick multi_model_selection;
  test_case "reopening shows connected models without adding them" `Quick already_bound_model_is_not_offered;
  test_case "pasted credentials preserve bytes and reject controls" `Quick pasted_credential_bytes;
  test_case "failed save refreshes revision and retains model" `Quick failed_save_refresh;
  test_case "a long reason is read whole" `Quick a_long_reason_is_read_whole;
  test_case "named default lane remains selected" `Quick named_default_identity;
  test_case "Unicode and late input HTTP response" `Quick unicode_and_late_input_response;
  test_case "verified save survives refresh failure" `Quick verified_save_refresh;
  test_case "saved activation retry cannot repeat save or login" `Quick saved_activation_retry;
  test_case "closed activation retains its request and recovery receipt" `Quick closed_activation_recovery;
  test_case "closed activation recovery preserves multiple accounts" `Quick closed_activation_accounts;
  test_case "generated account ID restores its saved activation" `Quick generated_account_activation_recovery;
  test_case "failed activation cannot start another login" `Quick failed_activation_blocks_login_shortcuts;
  test_case "a usage-limited save names what was not measured" `Quick usage_limited_save;
  test_case "visible save preserves durability uncertainty without resubmitting" `Quick uncertain_durability_save;
  test_case "lock warning survives refresh without exposing diagnostics" `Quick uncertain_lock_release_save;
  test_case "a partly checked save summarizes retained connections and names failures" `Quick partly_checked_save;
  test_case "unknown context follows supported provider route" `Quick missing_model_context;
  test_case "fragmented remote login" `Quick decoder_fragments;
  test_case "malformed and unfinished streams" `Quick decoder_failures;
  test_case "explicit provider and preserved default" `Quick account_and_default;
  test_case "private input and superseded attempt" `Quick input_and_epoch;
  test_case "declared fallback inventory contract" `Quick inventory_selection_contract;
  test_case "account emails beside provider rows" `Quick account_emails_beside_providers;
  test_case "clients first, then a client's accounts" `Quick clients_then_accounts;
  test_case "a client without a catalog entry" `Quick a_client_without_a_catalog_entry;
  test_case "a later read keeps its view" `Quick a_later_read_keeps_its_view;
  test_case "a pending login belongs to the request" `Quick a_pending_login_belongs_to_the_request;
  test_case "no account to log in" `Quick no_account_to_log_in;
  test_case "emails for the overview" `Quick emails_for_the_overview;
  test_case "every server email row decodes" `Quick server_email_rows_round_trip;
  test_case "spawn failure retains recovery receipt" `Quick failed_before_started;
  test_case "retry preserves early input until a new session starts" `Quick retry_early_input;
  test_case "visible cursor and recovery identity" `Quick viewport_and_receipt;
  test_case "official client colours are drawn" `Quick official_client_colours;
  test_case "foreign escapes never reach the terminal" `Quick foreign_escapes_never_reach_the_terminal;
  test_case "removal from the list" `Quick removal_from_the_list;
  test_case "refused removal" `Quick refused_removal]]
