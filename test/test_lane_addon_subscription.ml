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
let call config caller args =
  S.handle ~access:(Lane_addon_sources.Keeper caller) ~config ~caller args
let operator_call config args = S.handle ~access:Lane_addon_sources.Operator_configuration ~config ~caller:"operator" args
let save config = operator_call config (`Assoc ["operation",`String "save";"subscriptions",`List [subscription]]) |> ok
let store config = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons")
let producer ?(visibility=`Assoc ["kind",`String "shared"]) ?(phase=T.phase_to_json T.Attached) store id seq = Store.save_binding store ~instance_id:id
  (`Assoc ["visibility",visibility;
    "source_access",Lane_addon_sources.access_to_json Lane_addon_sources.Operator_configuration;
    "instance_id",`String id;"run_id",`String "study";"configuration",`Assoc ["id",`String "documents"];
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
let shared_producer_requires_subscription_owner_for_read_and_ack () = with_workspace (fun config ->
  ignore (save config);
  let retained = store config in
  producer retained "shared-instance" 1;
  append retained "shared-instance" 1;
  let read = args "read" in
  let untrusted operation = S.handle ~access:Lane_addon_sources.Unauthenticated
    ~config ~caller:"researcher" operation in
  check bool "attributed name cannot read a shared subscribed source" true
    (Result.is_error (untrusted read));
  let first = call config "researcher" read |> ok in
  check int "authenticated owner reads one named shared row" 1
    (member "output" first |> member "rows" |> Yojson.Safe.Util.to_list |> List.length);
  check bool "valid operator can read by explicit configuration authority" true
    (Result.is_ok (S.handle ~access:Lane_addon_sources.Operator_configuration
      ~config ~caller:"researcher" read));
  let cursor_path = Filename.concat (Filename.concat (Store.root retained) "subscriptions")
    (Store.digest (Yojson.Safe.to_string subscription) ^ ".json") in
  let acknowledge = `Assoc (("operation",`String "acknowledge")
    :: ("receipt",receipt first) :: selection) in
  check bool "attributed name cannot acknowledge the owner's shared cursor" true
    (Result.is_error (untrusted acknowledge));
  check bool "refused acknowledgment left no cursor" false (Sys.file_exists cursor_path);
  check bool "different verified Keeper cannot use the attributed owner name" true
    (Result.is_error (S.handle ~access:(Lane_addon_sources.Keeper "foreign")
      ~config ~caller:"researcher" read));
  check bool "owner's first receipt remains next after refusals" true
    (receipt (call config "researcher" read |> ok) = receipt first);
  ignore (ack config (receipt first) |> ok);
  check bool "verified owner's acknowledgment commits its cursor" true
    (Sys.file_exists cursor_path))
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
  let edit_run run = function
    | `Assoc fields -> `Assoc (("run_id",`String run) :: List.remove_assoc "run_id" fields)
    | _ -> assert false in
  let edited = edit_run "study-edited" subscription in
  ignore (save (Lane_addon_sources.Keeper "researcher") "researcher" [edited] |> ok);
  let other_view = inspect "other" in
  check bool "A edit preserves B's filtered subscription" true
    (Yojson.Safe.sort (member "subscriptions" other_view) = Yojson.Safe.sort (`List [other]));
  let edited_other = edit_run "study-other-edited" other in
  ignore (save (Lane_addon_sources.Keeper "other") "other" [edited_other] |> ok);
  check bool "B edit preserves A's filtered subscription" true
    (Yojson.Safe.sort (member "subscriptions" (inspect "researcher"))
     = Yojson.Safe.sort (`List [edited]));
  ignore (save (Lane_addon_sources.Keeper "researcher") "researcher" [] |> ok);
  let all = operator_call config (`Assoc ["operation",`String "inspect"]) |> ok in
  check bool "removing own rows preserves every hidden foreign row" true
    (Yojson.Safe.sort (member "subscriptions" all) = Yojson.Safe.sort (`List [edited_other]));
  ignore (operator_call config (`Assoc ["operation",`String "save";
    "expected_source_revision",member "source_revision" all;"subscriptions",`List []]) |> ok);
  check int "explicit operator can still replace the complete configuration" 0
    (operator_call config (`Assoc ["operation",`String "inspect"]) |> ok |> member "subscriptions"
      |> Yojson.Safe.Util.to_list |> List.length))
let hidden_and_absent_producers_have_identical_notices () = with_workspace (fun config ->
  ignore (save config);
  let notice () = call config "researcher" (`Assoc ["operation", `String "inspect"])
    |> ok |> member "reader_states" in
  let absent = notice () in
  let retained = store config in
  let visibility = `Assoc ["kind", `String "keeper"; "keeper", `String "foreign"] in
  producer ~visibility retained "private-a" 1;
  check bool "private producer is indistinguishable from absence" true (notice () = absent);
  producer ~visibility ~phase:(`Assoc ["kind", `String "invalid-private-phase"])
    retained "private-a" 1;
  check bool "private lifecycle errors do not reveal the producer" true (notice () = absent);
  producer ~visibility retained "private-b" 1;
  check bool "multiple private producers do not expose their count" true (notice () = absent))

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
  check bool "a file above the binding is not committed and is not read" true
    (Result.is_error (call config "researcher" (args "read")));
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
    ~access:(Lane_addon_sources.Keeper "researcher") ~replace_cursor_file ~sync_file:Unix.fsync ~sync_parent ~config ~caller:"researcher" operation in
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

let shared_turn_inputs_keep_private_sources_and_original_owner () =
  let wiki_key = Env_config_keeper.KeeperWikiContents.enabled_env_key in
  let with_wiki enabled operation =
    let previous = Sys.getenv_opt wiki_key in
    Unix.putenv wiki_key (if enabled then "true" else "false");
    Fun.protect ~finally:(fun () -> match previous with
      | None -> Unix.unsetenv wiki_key | Some value -> Unix.putenv wiki_key value) operation in
  with_wiki true (fun () -> with_workspace (fun config ->
  ignore (save config);
  let retained = store config in
  let visibility = `Assoc ["kind",`String "keeper";"keeper",`String "researcher"] in
  producer ~visibility retained "private-turn-input" 1;
  append retained "private-turn-input" 1;
  let first_receipt = receipt (call config "researcher" (args "read") |> ok) in
  let wiki = {Tool_wiki.base_path=config.base_path;agent_name="fixture"} in
  ignore (Tool_wiki.dispatch wiki ~name:"masc_wiki_create"
    ~args:(`Assoc ["page",`String "retained-page";"title",`String "Retained page";
      "summary",`String "Reference only";"source",`String "research";
      "body",`String "PRIVATE_PAGE_BODY"]));
  check bool "the real wiki fixture was created" true
    (Sys.file_exists (Tool_wiki.page_path ~base_path:config.base_path "retained-page"));
  let ledger = Filename.concat (Workspace_memory_ledger.directory ~base_path:config.base_path) "ledger.json" in
  Fs_compat.mkdir_p (Filename.dirname ledger);
  Out_channel.with_open_text ledger (fun channel -> Out_channel.output_string channel "{invalid ledger");
  let read ?preview () = Keeper_turn_shared_inputs.observe ?preview ~config ~keeper_name:"researcher" () in
  let reference = read () in
  check bool "an unavailable ledger does not erase independent private references or wiki entries" true
    (match reference with
     | {lane_updates=Ok (`List [_]);workspace_memory=Unavailable _;wiki_contents=Listed [_]} -> true
     | {lane_updates=_;workspace_memory=_;wiki_contents=_} -> false);
  let previous = Domain_pool_ref.get () in
  Fun.protect ~finally:(fun () -> match previous with
    | Some pool -> Domain_pool_ref.set pool | None -> Domain_pool_ref.clear_for_tests ()) (fun () ->
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Domain_pool_ref.clear_for_tests ();
    check bool "Eio without a process pool preserves all three source results" true (read () = reference);
    let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
    Domain_pool_ref.set pool;
    let owner = Keeper_interrupt_token.fresh () in
    let original = Ids.Turn_ref.make ~trace_id:"shared-input-owner" ~absolute_turn:5 in
    let preview = Keeper_turn_preview_owner.with_owner ~interrupt_token:owner ~observation:(Keeper_turn_preview_owner.create_turn_observation ()) (fun () ->
      Keeper_turn_preview.reset ~keeper_name:"researcher" ~execution_scope:None ~turn_ref:(Some original)
        ~now:0. ~redaction:Keeper_secret_redaction.empty) in
    check bool "pool-backed input preparation preserves the original source products" true
      (read ~preview () = reference);
    let module P = Keeper_turn_preview in
    let current () = match P.current_for_turn ~keeper_name:"researcher" ~interrupt_token:owner with
      | Some current -> current | None -> fail "original preparation writer missing" in
    let check_sources expected =
      let spans = P.preparation_spans (current ()).preparation_timeline in
      let parent = match List.find_opt (fun (span : P.preparation_span) ->
          span.preparation.phase=P.World_preparation) (List.rev spans) with
        | Some parent -> parent | None -> fail "world scope missing" in
      let children = List.filter (fun (span : P.preparation_span) ->
          span.parent_scope_id=Some parent.scope_id) spans in
      check int "all actual source branches retain the same proven world parent" 3 (List.length children);
      List.iter (fun (phase,outcome) ->
        match List.find_opt (fun (span : P.preparation_span) -> span.preparation.phase=phase) children with
        | Some {preparation={turn_ref=Some actual;state=Preparation_finished {outcome=actual_outcome;_};_};_} ->
          check bool "each source retains its original turn and actual availability outcome" true
            (Ids.Turn_ref.equal actual original && actual_outcome=outcome)
        | Some _ | None -> fail "source observation was lost or left active") expected;
      check bool "the world joins results without claiming all sources were available" true
        (match parent.preparation.state with Preparation_finished {outcome=Prepared;_} -> true
         | Preparation_active | Preparation_finished _ -> false)
    in
    check_sources [P.Lane_inputs_preparation,P.Prepared;
      P.Workspace_memory_preparation,P.Rejected;P.Wiki_preparation,P.Prepared];
    check bool "actual world preparation retains its original Owner and turn reference" true
      (match Keeper_turn_preview.current_for_turn ~keeper_name:"researcher" ~interrupt_token:owner with
       | Some {preparation=Some {phase=World_preparation;turn_ref=Some actual;
           state=Preparation_finished {outcome=Prepared;_};_};_} -> Ids.Turn_ref.equal actual original
       | Some _ | None -> false);
    check bool "shared-input preparation remains usable inside a single existing worker" true
      (Domain_pool.submit_io ~name:__FUNCTION__ pool (fun () -> read ()) = reference);
    let foreign = Keeper_turn_shared_inputs.observe ~config ~keeper_name:"foreign" () in
    check bool "parallel discovery never adopts another Keeper's private subscription" true
      (foreign.lane_updates = Ok (`List []));
    check bool "discovery does not acknowledge the pending original receipt" true
      (receipt (call config "researcher" (args "read") |> ok) = first_receipt);
    let payload = P.to_json ~include_preparation_timeline:true (current ()) in
    let wire = `Assoc ["schema",`String "masc.keeper_turns.v1";
      "keepers",`List [`Assoc ["keeper_name",`String "researcher";"status",`String "ok";
        "turn",`Assoc ["lane",`String "maintenance";"interrupt_token",`String (Keeper_interrupt_token.to_string owner);
          "turn_ref",Ids.Turn_ref.to_yojson original;"started_at_unix",`Float 0.;"preview",payload]]]] in
    (match Tui_decode.decode_keeper_turns wire with
     | Ok [{ktr_state=Keeper_turn_running {preview=Some decoded;_};_}] ->
       check bool "all source phases pass the actual selected turns decoder" true
         (Option.map P.preparation_spans decoded.ktp_preparation_timeline
          = Some (P.preparation_spans (current ()).preparation_timeline))
     | Ok _ -> fail "source history missing in actual turns response"
     | Error detail -> fail detail);
    let subscription_path = operator_call config (`Assoc ["operation",`String "inspect"])
      |> ok |> member "source_path" |> Yojson.Safe.Util.to_string in
    let original_subscriptions = In_channel.with_open_text subscription_path In_channel.input_all in
    Sys.remove ledger;
    let unavailable_lane = Fun.protect
        ~finally:(fun () -> Out_channel.with_open_text subscription_path (fun out ->
          Out_channel.output_string out original_subscriptions))
        (fun () ->
          Out_channel.with_open_text subscription_path (fun out -> output_string out "[broken subscriptions");
          let inputs = with_wiki false (fun () -> read ~preview ()) in
          check_sources [P.Lane_inputs_preparation,P.Rejected;
            P.Workspace_memory_preparation,P.Prepared;P.Wiki_preparation,P.Prepared];
          inputs) in
    check bool "unreadable Lane, missing memory and disabled wiki retain distinct original states" true
      (match unavailable_lane with
       | {lane_updates=Error _;workspace_memory=Missing;wiki_contents=Off} -> true
       | {lane_updates=_;workspace_memory=_;wiki_contents=_} -> false);
    let wiki_root = Tool_wiki.wiki_root ~base_path:config.base_path in
    let backup = wiki_root ^ ".source-wait-fixture" in
    Sys.rename wiki_root backup;
    Fun.protect ~finally:(fun () ->
      if Sys.file_exists wiki_root then Sys.remove wiki_root;
      Sys.rename backup wiki_root) (fun () ->
      Out_channel.with_open_text wiki_root (fun out -> output_string out "not a wiki directory");
      let inputs = read ~preview () in
      check_sources [P.Lane_inputs_preparation,P.Prepared;
        P.Workspace_memory_preparation,P.Prepared;P.Wiki_preparation,P.Rejected];
      check bool "unavailable wiki retains its typed result without erasing private Lane references" true
        (match inputs with
         | {lane_updates=Ok (`List [_]);workspace_memory=Missing;wiki_contents=Unlisted _} -> true
         | {lane_updates=_;workspace_memory=_;wiki_contents=_} -> false);
      List.iter (fun (name,args) ->
        match Tool_wiki.dispatch wiki ~name ~args with
        | Some result -> check bool "Wiki tools report an unavailable root as a typed runtime failure" true
            (Tool_result.failure_class result=Some Tool_result.Runtime_failure)
        | None -> fail "registered Wiki reader was not dispatched")
        ["masc_wiki_list",`Assoc [];
         "masc_wiki_read",`Assoc ["topic",`String "retained-page"];
         "masc_wiki_search",`Assoc ["query",`String "Reference"];
         "masc_wiki_lint",`Assoc []];
      Sys.remove wiki_root;
      let missing_wiki = read ~preview () in
      check_sources [P.Lane_inputs_preparation,P.Prepared;
        P.Workspace_memory_preparation,P.Prepared;P.Wiki_preparation,P.Prepared];
      check bool "a truly missing Wiki root remains an observed empty source" true
        (match missing_wiki.wiki_contents with Keeper_wiki_contents.Listed [] -> true
         | Off | Listed (_::_) | Unlisted _ -> false));
    check bool "later source repair never erases the original memory failure observation" true
      (List.exists (fun (span : P.preparation_span) ->
        span.preparation.phase=P.Workspace_memory_preparation
        && match span.preparation.state with Preparation_finished {outcome=Rejected;_} -> true
           | Preparation_active | Preparation_finished _ -> false)
        (P.preparation_spans (current ()).preparation_timeline));
    check bool "observation across failures never acknowledges original retained work" true
      (receipt (call config "researcher" (args "read") |> ok)=first_receipt))))))

let () = run "Lane subscription use" ["operator scenarios",[
  test_case "shared turn inputs retain source authority and original preparation ownership" `Quick
    shared_turn_inputs_keep_private_sources_and_original_owner;
  test_case "shared subscription requires verified cursor owner" `Quick
    shared_producer_requires_subscription_owner_for_read_and_ack;
  test_case "hidden and absent producers share one notice" `Quick hidden_and_absent_producers_have_identical_notices;
  test_case "Keeper saves preserve hidden subscriptions" `Quick keeper_save_preserves_hidden_subscriptions;
  test_case "private producer enforces durable owner and verified access" `Quick private_producer_requires_real_owner_access;
  test_case "staged cursor publication survives durability failure and exact retry" `Quick cursor_publication_requires_durable_visibility;
  test_case "producer lifecycle must decode before reading or acknowledging" `Quick producer_phase_preserves_position;
  test_case "cursor identity and incomplete source remain distinct" `Quick cursor_identity_and_incomplete_source;
  test_case "reference discovery, explicit reading and durable acknowledgement" `Quick read_ack_and_restart;
  test_case "missing records and configuration conflicts preserve position" `Quick failures_preserve_position]]
