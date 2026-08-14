open Alcotest
open Masc

module Broadcast_wakeup = Server_bootstrap_loops.For_testing

let test_mention_wakes_target () =
  match Broadcast_wakeup.broadcast_mention_wakeup_action (Some "rondo") with
  | `Wake_keeper "rondo" -> ()
  | `Wake_keeper other -> failf "unexpected wake target: %s" other
  | `Suppress_no_target -> fail "expected explicit mention to wake target"

let test_none_is_passive () =
  match Broadcast_wakeup.broadcast_mention_wakeup_action None with
  | `Suppress_no_target -> ()
  | `Wake_keeper target -> failf "unexpected no-target wake: %s" target

let test_blank_is_passive () =
  match Broadcast_wakeup.broadcast_mention_wakeup_action (Some "  ") with
  | `Suppress_no_target -> ()
  | `Wake_keeper target -> failf "unexpected blank-target wake: %s" target

let make_meta ?(mention_targets = []) name =
  match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ]) with
  | Ok meta ->
    { meta with Keeper_meta_contract.mention_targets = mention_targets }
  | Error detail -> failf "keeper meta fixture failed: %s" detail
;;

let delivery ~target ~request_id ~seq ~content : Workspace_broadcast.broadcast_delivery =
  { request_id
  ; seq
  ; rendered = content
  ; from_agent = "external-agent"
  ; content
  ; mention = Some target
  ; msg_type = "broadcast"
  }
;;

let with_workspace f =
  let root = Filename.temp_file "broadcast-wakeup-" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config root in
  ignore (Workspace.init config ~agent_name:None);
  Fun.protect
    ~finally:(fun () ->
      ignore (Workspace.reset config);
      Unix.rmdir root)
    (fun () -> f config)
;;

let persist_meta ?mention_targets config name =
  match Keeper_meta_store.replace_snapshot config (make_meta ?mention_targets name) with
  | Ok () -> ()
  | Error detail -> failf "keeper meta persistence failed: %s" detail
;;

let count_delivery_rows ~base_path ~keeper_name ~request_id =
  Keeper_chat_store.load_all ~base_dir:base_path ~keeper_name
  |> List.filter (fun (message : Keeper_chat_store.chat_message) ->
    message.external_message_id = Some request_id)
  |> List.length
;;

let test_delivery_appends_once_before_wake () =
  with_workspace @@ fun config ->
  let target = "rondo" in
  let request_id = "wmsg-0011223344556677" in
  persist_meta config target;
  let wakes = ref 0 in
  let delivery = delivery ~target ~request_id ~seq:1 ~content:"review this" in
  let deliver () =
    Broadcast_wakeup.deliver_broadcast_mention
      ~config
      ~base_path:config.base_path
      ~is_running:(fun _ -> true)
      ~wakeup:(fun _ -> incr wakes)
      delivery
  in
  (match deliver () with
   | Server_bootstrap_loops.Broadcast_persisted_and_woken "rondo" -> ()
   | _ -> fail "committed delivery did not wake the running keeper");
  (match deliver () with
   | Server_bootstrap_loops.Broadcast_persisted_and_woken "rondo" -> ()
   | _ -> fail "idempotent replay did not preserve wake eligibility");
  check int "one accepted-user row" 1
    (count_delivery_rows ~base_path:config.base_path ~keeper_name:target ~request_id);
  check int "wake only follows successful append outcomes" 2 !wakes
;;

let test_stopped_keeper_persists_without_wake () =
  with_workspace @@ fun config ->
  let target = "stopped-keeper" in
  let request_id = "wmsg-8899aabbccddeeff" in
  persist_meta config target;
  let wakes = ref 0 in
  let outcome =
    Broadcast_wakeup.deliver_broadcast_mention
      ~config
      ~base_path:config.base_path
      ~is_running:(fun _ -> false)
      ~wakeup:(fun _ -> incr wakes)
      (delivery ~target ~request_id ~seq:2 ~content:"persist while stopped")
  in
  (match outcome with
   | Server_bootstrap_loops.Broadcast_persisted_wake_deferred actual ->
     check string "deferred target" target actual
   | _ -> fail "stopped Keeper delivery was not durably deferred");
  check int "stopped delivery persisted" 1
    (count_delivery_rows ~base_path:config.base_path ~keeper_name:target ~request_id);
  check int "stopped Keeper not woken" 0 !wakes
;;

let test_runtime_agent_alias_resolves_before_delivery () =
  with_workspace @@ fun config ->
  let keeper_name = "rondo" in
  let target = Keeper_identity.keeper_agent_name keeper_name in
  let request_id = "wmsg-aabbccddeeff0011" in
  persist_meta config keeper_name;
  let woken = ref None in
  let outcome =
    Broadcast_wakeup.deliver_broadcast_mention
      ~config
      ~base_path:config.base_path
      ~is_running:(String.equal keeper_name)
      ~wakeup:(fun name -> woken := Some name)
      (delivery ~target ~request_id ~seq:3 ~content:"agent alias delivery")
  in
  (match outcome with
   | Server_bootstrap_loops.Broadcast_persisted_and_woken actual ->
     check string "canonical delivery target" keeper_name actual
   | _ -> fail "runtime agent alias did not resolve to the canonical Keeper");
  check (option string) "canonical wake target" (Some keeper_name) !woken;
  check int "delivery stored under canonical Keeper" 1
    (count_delivery_rows
       ~base_path:config.base_path
       ~keeper_name
       ~request_id);
  check int "no alias-named chat store" 0
    (count_delivery_rows ~base_path:config.base_path ~keeper_name:target ~request_id)
;;

let delivery_message ~base_path ~keeper_name ~request_id =
  Keeper_chat_store.load_all ~base_dir:base_path ~keeper_name
  |> List.find_opt (fun (message : Keeper_chat_store.chat_message) ->
    message.external_message_id = Some request_id)
;;

let test_configured_mention_alias_resolves_and_stamps_feed_target () =
  with_workspace @@ fun config ->
  let keeper_name = "rondo" in
  let alias = "sangsu" in
  let request_id = "wmsg-1122334455667788" in
  persist_meta ~mention_targets:[ alias ] config keeper_name;
  let outcome =
    Broadcast_wakeup.deliver_broadcast_mention
      ~config
      ~base_path:config.base_path
      ~is_running:(String.equal keeper_name)
      ~wakeup:(fun _ -> ())
      (delivery ~target:alias ~request_id ~seq:4 ~content:"alias delivery")
  in
  (match outcome with
   | Server_bootstrap_loops.Broadcast_persisted_and_woken actual ->
     check string "alias resolves to canonical Keeper" keeper_name actual
   | _ -> fail "configured mention alias did not resolve");
  match delivery_message ~base_path:config.base_path ~keeper_name ~request_id with
  | None -> fail "configured alias delivery was not persisted"
  | Some message ->
    let mentions =
      List.map Keeper_identity.Keeper_id.to_string message.mentions
    in
    check bool "persisted row carries configured feed target" true
      (List.mem alias mentions)
;;

let test_canonical_delivery_stamps_configured_feed_target () =
  with_workspace @@ fun config ->
  let keeper_name = "rondo" in
  let alias = "sangsu" in
  let request_id = "wmsg-8877665544332211" in
  persist_meta ~mention_targets:[ alias ] config keeper_name;
  ignore
    (Broadcast_wakeup.deliver_broadcast_mention
       ~config
       ~base_path:config.base_path
       ~is_running:(fun _ -> false)
       ~wakeup:(fun _ -> ())
       (delivery ~target:keeper_name ~request_id ~seq:5 ~content:"canonical delivery"));
  match delivery_message ~base_path:config.base_path ~keeper_name ~request_id with
  | None -> fail "canonical delivery was not persisted"
  | Some message ->
    let mentions =
      List.map Keeper_identity.Keeper_id.to_string message.mentions
    in
    check bool "canonical row carries configured feed target" true
      (List.mem alias mentions)
;;

let () =
  run
    "broadcast_wakeup_policy"
    [
      ( "mention_policy"
      , [
          test_case "explicit mention wakes target" `Quick test_mention_wakes_target
        ; test_case "no mention is passive" `Quick test_none_is_passive
        ; test_case "blank mention is passive" `Quick test_blank_is_passive
        ; test_case "delivery appends once before wake" `Quick
            test_delivery_appends_once_before_wake
        ; test_case "stopped Keeper persists without wake" `Quick
            test_stopped_keeper_persists_without_wake
        ; test_case "runtime agent alias resolves before delivery" `Quick
            test_runtime_agent_alias_resolves_before_delivery
        ; test_case "configured mention alias resolves and stamps feed target" `Quick
            test_configured_mention_alias_resolves_and_stamps_feed_target
        ; test_case "canonical delivery stamps configured feed target" `Quick
            test_canonical_delivery_stamps_configured_feed_target
        ] )
    ]
