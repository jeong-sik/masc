open Alcotest
open Masc
module S = Lane_addon_subscription
module Store = Lane_addon_store
module T = Lane_addon_types
let ok = function Ok value -> value | Error error -> fail error
let member = Yojson.Safe.Util.member
let append_observation store ~instance_id ~seq ~sources output =
  Store.append_observation store ~instance_id ~seq ~sources output
  |> Result.map_error Store.observation_write_error_to_string
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
let producer ?(phase=T.phase_to_json T.Attached) store id seq = Store.save_binding store ~instance_id:id
  (`Assoc ["instance_id",`String id;"run_id",`String "study";"configuration",`Assoc ["id",`String "documents"];
    "phase",phase;"observation_seq",`Int seq;
    "package",`Assoc ["outputs",`Assoc ["changes",`Assoc ["lanes",`List [`String "changes"]]];
      "resources",`Assoc ["max_reply_bytes",`Int 8192]]]) |> ok
let append ?(coverage=[]) store id seq =
  let row lane : T.row = {id=Printf.sprintf "%s/%d/%s" id seq lane;lane_id=id ^ "/" ^ lane;
    kind=T.Event;title="Source changed";observed_at=float_of_int seq;subject_id="document";
    clock=None;actor=None;fields=["raw",`String "private source body"];evidence=[];related_ids=[]} in
  append_observation store ~instance_id:id ~seq ~sources:(`List [])
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
  let expected_notice=`List [`Assoc ["subscription",subscription;
    "instance_id",`String "instance-1";"after_sequence",`Int 0;
    "latest_sequence",`Int 2;"new_observations",`Bool true;"replaced",`Bool false]] in
  check bool "notice contains only exact references and sequence metadata" true
    (Yojson.Safe.sort notice=Yojson.Safe.sort expected_notice);
  let first=call config "researcher" (args "read") |> ok in
  check int "named output excludes other rows" 1 (List.length (member "output" first |> member "rows" |> Yojson.Safe.Util.to_list));
  let repeated=call config "researcher" (args "read") |> ok in
  check bool "lost response can be read again" true (receipt first=receipt repeated);
  let manager_state () = call config "operator" (`Assoc ["operation",`String "inspect"])
    |> ok |> member "reader_states" |> Yojson.Safe.Util.to_list |> List.hd in
  check int "manager inspection does not turn reading into acknowledgment" 0
    (manager_state () |> member "after_sequence" |> Yojson.Safe.Util.to_int);
  ignore(ack config (receipt first) |> ok);
  check int "manager sees acknowledged position without impersonating reader" 1
    (manager_state () |> member "after_sequence" |> Yojson.Safe.Util.to_int);
  let second=call config "researcher" (args "read") |> ok in
  check int "new store handle resumes durable sequence" 2 (receipt second |> member "sequence" |> Yojson.Safe.Util.to_int);
  ignore (ack config (receipt first) |> ok);
  let same_second=call config "researcher" (args "read") |> ok in
  check bool "retrying the current receipt never acknowledges the next observation" true
    (receipt same_second=receipt second);
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
  ignore (ack config (receipt first) |> ok);
  check int "idempotent acknowledgement preserves the next unread sequence" 2
    (call config "researcher" (args "read") |> ok |> receipt |> member "sequence" |> Yojson.Safe.Util.to_int))

let producer_phase_preserves_position () = with_workspace (fun config ->
  let _saved = save config in
  let retained = store config in
  producer retained "instance-1" 2;
  append retained "instance-1" 1; append retained "instance-1" 2;
  let first = call config "researcher" (args "read") |> ok in
  let _acknowledged = ack config (receipt first) |> ok in
  let second = call config "researcher" (args "read") |> ok in
  let cursor_path = Filename.concat (Filename.concat (Store.root retained) "subscriptions")
    (Store.digest (Yojson.Safe.to_string subscription) ^ ".json") in
  let saved_cursor = Fs_compat.load_file cursor_path in
  List.iter (fun phase ->
    producer ~phase retained "instance-1" 2;
    check bool "unavailable phase cannot authorize a read" true
      (Result.is_error (call config "researcher" (args "read")));
    check bool "prior valid receipt cannot acknowledge an unavailable producer" true
      (Result.is_error (ack config (receipt second)));
    check string "refusal preserves the acknowledged cursor bytes" saved_cursor
      (Fs_compat.load_file cursor_path);
    let notice = S.observe ~config ~keeper_name:"researcher" |> ok in
    check bool "producer lifecycle failure remains visible" true
      (match notice with
       | `List [entry] -> (match member "unavailable" entry with `String _ -> true | _ -> false)
       | _ -> false))
    [`Null; `Assoc []; `Assoc ["kind",`String "unknown"];
     `Assoc ["kind",`String "attached";"unexpected",`Bool true];
     `Assoc ["kind",`String "failed"];
     `Assoc ["kind",`String "failed";"message",`Int 1];
     `Assoc ["kind",`String "attached";"kind",`String "attached"];
     T.phase_to_json T.Detaching; T.phase_to_json T.Detached];
  producer ~phase:`Null retained "malformed-peer" 0;
  producer retained "instance-1" 2;
  check bool "malformed peer prevents choosing an attached replacement" true
    (Result.is_error (call config "researcher" (args "read")));
  check bool "malformed peer prevents acknowledgement" true
    (Result.is_error (ack config (receipt second)));
  Store.remove_binding retained ~instance_id:"malformed-peer" |> ok;
  producer retained "instance-1" 1;
  let recovered = call config "researcher" (args "read") |> ok in
  check bool "retained high-water recovers observation beyond stale binding" true
    (receipt recovered = receipt second);
  List.iter (fun phase ->
    producer ~phase:(T.phase_to_json phase) retained "instance-1" 2;
    let readable = call config "researcher" (args "read") |> ok in
    check bool "valid live or failed phase keeps the same unread observation" true
      (receipt readable = receipt second)) [T.Attached; T.Observing; T.Failed "worker unavailable"];
  let _acknowledged = ack config (receipt second) |> ok in
  check bool "repaired lifecycle permits explicit acknowledgement" true
    (S.observe ~config ~keeper_name:"researcher" = Ok (`List [])))

let cursor_publication_requires_durable_visibility () = with_workspace (fun config ->
  ignore (save config);
  let retained=store config in producer retained "instance-1" 2;
  append retained "instance-1" 1;append retained "instance-1" 2;
  let first=call config "researcher" (args "read") |> ok in
  let first_receipt=receipt first in
  let cursor_path=Filename.concat (Filename.concat (Store.root retained) "subscriptions")
    (Store.digest (Yojson.Safe.to_string subscription) ^ ".json") in
  let staged ~before path bytes =
    Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
      ~sync_file:(fun path -> if before then raise (Unix.Unix_error (Unix.EIO,"fsync",path))
        else let fd=Unix.openfile path [Unix.O_RDONLY] 0 in
          Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd))
      ~sync_parent:(fun path -> raise (Unix.Unix_error (Unix.EIO,"fsync",path))) path bytes in
  let fault_call ~replace_cursor_file ~sync_parent operation = S.For_testing.handle
    ~replace_cursor_file ~sync_file:Unix.fsync ~sync_parent ~config ~caller:"researcher" operation in
  let ack_args=`Assoc (("operation",`String "acknowledge")::("receipt",first_receipt)::selection) in
  check bool "before-rename acknowledgement is rejected" true
    (Result.is_error (fault_call ~replace_cursor_file:(staged ~before:true) ~sync_parent:Unix.fsync ack_args));
  check bool "before-rename failure creates no cursor" false (Sys.file_exists cursor_path);
  check bool "before-rename preserves next unread receipt" true
    (receipt (call config "researcher" (args "read") |> ok)=first_receipt);
  let unknown=fault_call ~replace_cursor_file:(staged ~before:false) ~sync_parent:Unix.fsync ack_args |> ok in
  check bool "after-rename is not a durability acknowledgement" false
    (member "acknowledged" unknown |> Yojson.Safe.Util.to_bool);
  check bool "after-rename reports the actual publication" true
    (member "published" unknown |> Yojson.Safe.Util.to_bool);
  check string "durability remains explicit" "unconfirmed" (member "durability" unknown |> Yojson.Safe.Util.to_string);
  let published=Fs_compat.load_file cursor_path in
  check bool "the exact requested cursor is visible" true
    (Yojson.Safe.from_string published=first_receipt);
  let fail_sync _=raise (Unix.Unix_error (Unix.EIO,"fsync","cursor-parent")) in
  check bool "fresh reader refuses unresolved directory durability" true
    (Result.is_error (fault_call ~replace_cursor_file:Fs_compat.save_file_atomic_strict_staged
      ~sync_parent:fail_sync (args "read")));
  let notice=S.For_testing.observe ~sync_file:Unix.fsync ~sync_parent:fail_sync
    ~config ~keeper_name:"researcher" |> ok in
  check bool "restart-style discovery exposes unavailable instead of consumed output" true
    (match notice with `List [row] -> (match member "unavailable" row with `String _ -> true | _ -> false)
      | _ -> false);
  check string "failed verification does not rewrite cursor bytes" published (Fs_compat.load_file cursor_path);
  let recovered=ack config first_receipt |> ok in
  check bool "the exact pending receipt can be durably retried" true
    (member "acknowledged" recovered |> Yojson.Safe.Util.to_bool);
  check string "idempotent recovery leaves exact cursor bytes" published (Fs_compat.load_file cursor_path);
  let second=call config "researcher" (args "read") |> ok in
  check int "pending receipt retry never skips the following record" 2
    (receipt second |> member "sequence" |> Yojson.Safe.Util.to_int);
  ignore (ack config (receipt second) |> ok);
  check bool "an older receipt cannot move the acknowledged cursor backwards" true
    (Result.is_error (ack config first_receipt)))

let () = run "Lane subscription use" ["operator scenarios",[
  test_case "staged cursor publication survives durability failure and exact retry" `Quick cursor_publication_requires_durable_visibility;
  test_case "producer lifecycle must decode before reading or acknowledging" `Quick producer_phase_preserves_position;
  test_case "cursor identity and incomplete source remain distinct" `Quick cursor_identity_and_incomplete_source;
  test_case "reference discovery, explicit reading and durable acknowledgement" `Quick read_ack_and_restart;
  test_case "missing records and configuration conflicts preserve position" `Quick failures_preserve_position]]
