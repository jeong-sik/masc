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
let inventory = `Assoc ["setup_revision",`String "revision";"default_runtime_id",`String "primary";
  "runtimes",`List [`Assoc ["id",`String "fallback"];`Assoc ["id",`String "primary"]];
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
  check string "selected account survives model save" account
    (body |> member "connections" |> to_list |> List.hd |> member "source" |> member "account_ref" |> to_string);
  check bool "slash login is never Keeper text" true (Masc_tui_command.parse "/login muse"=Masc_tui_command.Account_login "muse")
let input_and_epoch () =
  let t=Login.create "codex" in t.phase<-Login.Logging;t.generation<-2;
  Login.paste t "private-code";
  check bool "render masks private input" false (List.exists (fun line -> line="private-code" || String.ends_with ~suffix:"private-code" line) (Login.lines t));
  (match Login.key t "\r" with
   | Login.Input (`Assoc fields) -> check bool "input goes to dedicated endpoint payload" true (List.assoc_opt "text" fields=Some (`String "private-code"))
   | _ -> fail "code was not submitted");
  check string "submitted code cleared" "" t.draft;
  ignore (Login.event ~generation:1 t Login.Input_ready);
  check bool "late previous input ACK cannot unlock new input" true t.input_pending;
  ignore (Login.event ~generation:1 t (Login.Complete(other,Login.Authenticated)));
  check bool "late account cannot replace current attempt" true (t.account_ref=None && t.phase=Login.Logging);
  ignore (Login.event ~generation:2 t Login.Input_ready);
  check bool "actual terminal Tab forwarded" true (Login.key t "\t"=Login.Input (`Assoc ["kind",`String "key";"key",`String "tab"]));
  check bool "cancel available while input pending" true (Login.key t "\003"=Login.Cancel)
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
let () = run "TUI account login" ["workflow",[
  test_case "fragmented remote login" `Quick decoder_fragments;
  test_case "malformed and unfinished streams" `Quick decoder_failures;
  test_case "explicit provider and preserved default" `Quick account_and_default;
  test_case "private input and superseded attempt" `Quick input_and_epoch;
  test_case "visible cursor and recovery identity" `Quick viewport_and_receipt]]
