open Alcotest
open Masc
module S = Lane_addon_subscription
module Store = Lane_addon_store
module T = Lane_addon_types
let ok = function Ok value -> value | Error error -> fail error
let member = Yojson.Safe.Util.member
let rec remove path = if Sys.is_directory path then (
  Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path)
  else Sys.remove path
let with_workspace f =
  let base = Filename.temp_dir "lane-subs-" "" in
  let old=Sys.getenv_opt "MASC_CONFIG_DIR" in
  Unix.putenv "MASC_CONFIG_DIR" (Filename.concat base ".masc/config");
  Fun.protect ~finally:(fun () ->
    Unix.putenv "MASC_CONFIG_DIR" (match old with None->""|Some value->value);
    remove base) (fun () -> f (Workspace.default_config base))
let subscription = `Assoc ["keeper_name",`String "researcher";"run_id",`String "study";
  "installation_id",`String "documents";"output_id",`String "changes"]
let selection = ["run_id",`String "study";"installation_id",`String "documents";"output_id",`String "changes"]
let args operation = `Assoc (("operation",`String operation)::selection)
let call config caller args = S.handle ~config ~caller args
let operator_call config args = S.handle ~access:Lane_addon_sources.Operator_configuration ~config ~caller:"operator" args
let save config = operator_call config (`Assoc ["operation",`String "save";"subscriptions",`List [subscription]]) |> ok
let store config = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons")
let producer ?(visibility=`Assoc ["kind",`String "shared"]) store id seq = Store.save_binding store ~instance_id:id
  (`Assoc ["visibility",visibility;"instance_id",`String id;"run_id",`String "study";"configuration",`Assoc ["id",`String "documents"];
    "phase",`Assoc ["kind",`String "attached"];"observation_seq",`Int seq;
    "package",`Assoc ["outputs",`Assoc ["changes",`Assoc ["lanes",`List [`String "changes"]]];
      "resources",`Assoc ["max_reply_bytes",`Int 8192]]]) |> ok
let append ?(coverage=[]) store id seq =
  let row lane : T.row = {id=Printf.sprintf "%s/%d/%s" id seq lane;lane_id=id ^ "/" ^ lane;
    kind=T.Event;title="Source changed";observed_at=float_of_int seq;subject_id="document";
    clock=None;actor=None;fields=["raw",`String "private source body"];evidence=[];related_ids=[]} in
  Store.append_observation store ~instance_id:id ~seq ~sources:(`List [])
    {rows=[row "changes";row "other-output"];coverage} |> ok
let receipt result = member "receipt" result
let ack config receipt = call config "researcher"
  (`Assoc (("operation",`String "acknowledge")::("receipt",receipt)::selection))
let private_producer_requires_real_owner_access () = with_workspace (fun config ->
  ignore (save config);
  let retained = store config in
  let visibility keeper = `Assoc ["kind",`String "keeper";"keeper",`String keeper] in
  producer ~visibility:(visibility "researcher") retained "private-instance" 1;
  append retained "private-instance" 1;
  let request = args "read" in
  check bool "local attribution cannot read private output" true
    (Result.is_error (S.handle ~access:Lane_addon_sources.Unauthenticated ~config ~caller:"researcher" request));
  let hidden = S.handle ~access:Lane_addon_sources.Unauthenticated ~config ~caller:"researcher"
    (`Assoc ["operation",`String "inspect"]) |> ok in
  check int "unverified attribution reveals no private subscription identity" 0
    (member "subscriptions" hidden |> Yojson.Safe.Util.to_list |> List.length);
  let first = call config "researcher" request |> ok in
  check int "actual owner receives complete named private output" 1
    (member "output" first |> member "rows" |> Yojson.Safe.Util.to_list |> List.length);
  producer ~visibility:(visibility "another-owner") retained "private-instance" 1;
  check bool "foreign owner cannot read retained bytes" true
    (Result.is_error (call config "researcher" request));
  check bool "foreign owner cannot acknowledge an old receipt" true
    (Result.is_error (ack config (receipt first)));
  producer ~visibility:(visibility "researcher") retained "private-instance" 1;
  check bool "denied acknowledgment preserved unread position" true
    (receipt (call config "researcher" request |> ok) = receipt first);
  producer ~visibility:(`Assoc ["kind",`String "unknown"]) retained "private-instance" 1;
  check bool "unknown durable visibility fails closed" true
    (Result.is_error (call config "researcher" request));
  Store.save_binding retained ~instance_id:"private-instance"
    (`Assoc ["instance_id",`String "private-instance";"run_id",`String "study";
      "configuration",`Assoc ["id",`String "documents"];"phase",`Assoc ["kind",`String "attached"]]) |> ok;
  check bool "missing durable visibility fails closed" true
    (Result.is_error (call config "researcher" request));
  producer ~visibility:(visibility "another-owner") retained "private-instance" 1;
  check bool "explicit operator authority can read retained private output" true
    (Result.is_ok (S.handle ~access:Lane_addon_sources.Operator_configuration ~config ~caller:"researcher" request)))
let keeper_save_preserves_hidden_subscriptions () = with_workspace (fun config ->
  let other = match subscription with `Assoc fields ->
    `Assoc (("keeper_name",`String "other") :: List.remove_assoc "keeper_name" fields)
    | _ -> assert false in
  ignore (operator_call config (`Assoc ["operation",`String "save";
    "subscriptions",`List [subscription;other]]) |> ok);
  let inspect caller = call config caller (`Assoc ["operation",`String "inspect"]) |> ok in
  let own = inspect "researcher" in
  check int "foreign rows remain hidden" 1 (member "subscriptions" own |> Yojson.Safe.Util.to_list |> List.length);
  let save access caller rows = S.handle ~access ~config ~caller (`Assoc ["operation",`String "save";
    "expected_source_revision",member "source_revision" (inspect caller);"subscriptions",`List rows]) in
  check bool "Keeper cannot submit foreign ownership" true
    (Result.is_error (save (Lane_addon_sources.Keeper "researcher") "researcher" [other]));
  check bool "unverified caller cannot replace the file" true
    (Result.is_error (save Lane_addon_sources.Unauthenticated "researcher" []));
  check bool "access/caller disagreement refuses save" true
    (Result.is_error (save (Lane_addon_sources.Keeper "other") "researcher" []));
  ignore (save (Lane_addon_sources.Keeper "researcher") "researcher" [] |> ok);
  let all = operator_call config (`Assoc ["operation",`String "inspect"]) |> ok in
  check bool "removing own rows preserves every hidden foreign row" true
    (member "subscriptions" all = `List [other]);
  ignore (operator_call config (`Assoc ["operation",`String "save";
    "expected_source_revision",member "source_revision" all;"subscriptions",`List []]) |> ok);
  check int "explicit operator can still replace the complete configuration" 0
    (operator_call config (`Assoc ["operation",`String "inspect"]) |> ok |> member "subscriptions"
      |> Yojson.Safe.Util.to_list |> List.length))
let read_ack_and_restart () = with_workspace (fun config ->
  ignore(save config);let store=store config in producer store "instance-1" 2;
  append store "instance-1" 1;append store "instance-1" 2;
  check bool "unsubscribed Keeper receives no context" true
    (S.observe ~config ~keeper_name:"other"=Ok (`List []));
  let notice=S.observe ~config ~keeper_name:"researcher" |> ok in
  let expected_notice=`List [`Assoc ["subscription",subscription;
    "instance_id",`String "instance-1";"after_sequence",`Int 0;
    "latest_sequence",`Int 2;"new_observations",`Bool true;"replaced",`Bool false]] in
  check bool "notice contains only exact references and sequence metadata" true
    (Yojson.Safe.sort notice=Yojson.Safe.sort expected_notice);
  let first=call config "researcher" (args "read") |> ok in
  check int "named output excludes other rows" 1 (List.length (member "output" first |> member "rows" |> Yojson.Safe.Util.to_list));
  let repeated=call config "researcher" (args "read") |> ok in
  check bool "lost response can be read again" true (receipt first=receipt repeated);
  let manager_state () = operator_call config (`Assoc ["operation",`String "inspect"])
    |> ok |> member "reader_states" |> Yojson.Safe.Util.to_list |> List.hd in
  check int "manager inspection does not turn reading into acknowledgment" 0
    (manager_state () |> member "after_sequence" |> Yojson.Safe.Util.to_int);
  ignore(ack config (receipt first) |> ok);
  check int "manager sees acknowledged position without impersonating reader" 1
    (manager_state () |> member "after_sequence" |> Yojson.Safe.Util.to_int);
  let second=call config "researcher" (args "read") |> ok in
  check int "new store handle resumes durable sequence" 2 (receipt second |> member "sequence" |> Yojson.Safe.Util.to_int);
  check bool "old receipt cannot acknowledge a new observation" true (Result.is_error (ack config (receipt first)));
  ignore(ack config (receipt second) |> ok);
  check bool "unchanged consumed output adds no context" true (S.observe ~config ~keeper_name:"researcher"=Ok (`List []));
  check bool "another Keeper cannot read the subscription" true (Result.is_error (call config "other" (args "read"))))
let failures_preserve_position () = with_workspace (fun config ->
  ignore(save config);let store=store config in producer store "instance-1" 1;
  check bool "missing record fails instead of advancing" true (Result.is_error (call config "researcher" (args "read")));
  append store "instance-1" 1;
  let first=call config "researcher" (args "read") |> ok in
  check int "repaired record is still the next unread sequence" 1 (receipt first |> member "sequence" |> Yojson.Safe.Util.to_int);
  let saved=operator_call config (`Assoc ["operation",`String "inspect"]) |> ok in
  check bool "stale subscription save rejected" true
    (Result.is_error (operator_call config (`Assoc ["operation",`String "save";"subscriptions",`List []])));
  let revision=member "source_revision" saved in
  ignore(operator_call config (`Assoc ["operation",`String "save";"expected_source_revision",revision;"subscriptions",`List []]) |> ok);
  check bool "removal stops next-turn discovery" true (S.observe ~config ~keeper_name:"researcher"=Ok (`List [])))
let cursor_identity_and_incomplete_source () = with_workspace (fun config ->
  ignore(save config);
  let retained=store config in producer retained "instance-1" 2;
  let coverage : T.coverage = {source_id="documents";incarnation="source-1";
    cursor=None;complete=false;detail=Some "upstream acquisition unavailable"} in
  append ~coverage:[coverage] retained "instance-1" 1;
  append retained "instance-1" 2;
  let first=call config "researcher" (args "read") |> ok in
  check bool "readable retained output does not imply complete source input" false
    (member "complete" first |> Yojson.Safe.Util.to_bool);
  ignore(ack config (receipt first) |> ok);
  let cursor_path=Filename.concat (Filename.concat (Store.root retained) "subscriptions")
    (Store.digest (Yojson.Safe.to_string subscription) ^ ".json") in
  let saved=Fs_compat.load_file cursor_path in
  let replace key value json = match json with
    | `Assoc fields -> `Assoc ((key,value)::List.remove_assoc key fields)
    | _ -> fail "expected receipt object" in
  let foreign=replace "subscription" (replace "output_id" (`String "other-output") subscription)
    (receipt first) in
  let malformed=replace "output_sha256" (`String "not-a-sha256") (receipt first) in
  let incomplete=`Assoc ["instance_id",`String "instance-1";"sequence",`Int 1] in
  List.iter (fun corrupt ->
    Fs_compat.save_file_atomic_strict cursor_path (Yojson.Safe.to_string corrupt) |> ok;
    check bool "untrusted cursor cannot skip unread output" true
      (Result.is_error (call config "researcher" (args "read")));
    check bool "untrusted cursor cannot acknowledge the next record" true
      (Result.is_error (ack config (receipt first)));
    let notice=S.observe ~config ~keeper_name:"researcher" |> ok in
    check bool "cursor corruption remains visible to the Keeper" true
      (match notice with
       | `List [entry] -> (match member "unavailable" entry with `String _ -> true | _ -> false)
       | _ -> false)) [foreign;malformed;incomplete];
  Fs_compat.save_file_atomic_strict cursor_path saved |> ok;
  let second=call config "researcher" (args "read") |> ok in
  check int "repair resumes after only the acknowledged receipt" 2
    (receipt second |> member "sequence" |> Yojson.Safe.Util.to_int);
  check bool "incomplete-source acknowledgment remains durable" true
    (Result.is_error (ack config (receipt first))))

let () = run "Lane subscription use" ["operator scenarios",[
  test_case "private producer enforces durable owner and verified access" `Quick private_producer_requires_real_owner_access;
  test_case "cursor identity and incomplete source remain distinct" `Quick cursor_identity_and_incomplete_source;
  test_case "Keeper save preserves hidden subscriptions" `Quick keeper_save_preserves_hidden_subscriptions;
  test_case "reference discovery, explicit reading and durable acknowledgement" `Quick read_ack_and_restart;
  test_case "missing records and configuration conflicts preserve position" `Quick failures_preserve_position]]
