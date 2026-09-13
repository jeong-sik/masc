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
let save config = call config "operator" (`Assoc ["operation",`String "save";"subscriptions",`List [subscription]]) |> ok
let store config = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons")
let producer store id seq = Store.save_binding store ~instance_id:id
  (`Assoc ["instance_id",`String id;"run_id",`String "study";"configuration",`Assoc ["id",`String "documents"];
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
let read_ack_and_restart () = with_workspace (fun config ->
  ignore(save config);let store=store config in producer store "instance-1" 2;
  append store "instance-1" 1;append store "instance-1" 2;
  check bool "unsubscribed Keeper receives no context" true
    (S.observe ~config ~keeper_name:"other"=Ok (`List []));
  let notice=S.observe ~config ~keeper_name:"researcher" |> ok in
  check bool "notice contains only references" false
    (String_util.contains_substring (Yojson.Safe.to_string notice) "private source body");
  let first=call config "researcher" (args "read") |> ok in
  check int "named output excludes other rows" 1 (List.length (member "output" first |> member "rows" |> Yojson.Safe.Util.to_list));
  let repeated=call config "researcher" (args "read") |> ok in
  check bool "lost response can be read again" true (receipt first=receipt repeated);
  ignore(ack config (receipt first) |> ok);
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
  let saved=call config "operator" (`Assoc ["operation",`String "inspect"]) |> ok in
  check bool "stale subscription save rejected" true
    (Result.is_error (call config "operator" (`Assoc ["operation",`String "save";"subscriptions",`List []])));
  let revision=member "source_revision" saved in
  ignore(call config "operator" (`Assoc ["operation",`String "save";"expected_source_revision",revision;"subscriptions",`List []]) |> ok);
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
  test_case "cursor identity and incomplete source remain distinct" `Quick cursor_identity_and_incomplete_source;
  test_case "reference discovery, explicit reading and durable acknowledgement" `Quick read_ack_and_restart;
  test_case "missing records and configuration conflicts preserve position" `Quick failures_preserve_position]]
