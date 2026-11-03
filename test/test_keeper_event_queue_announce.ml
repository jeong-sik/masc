(* RFC-0480 §3.4: a write to a Keeper's event queue or reaction record tells
   that workspace's readers which Keeper changed. *)

open Alcotest
open Masc

(* Long enough for the announcing fiber to wake on an idle machine. *)
let signal_wait_s = 5.0

let ignore_writes ~base_path:_ ~keeper_name:_ = ()

let stimulus post_id : Keeper_event_queue.stimulus =
  { post_id
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = Unix.gettimeofday ()
  ; payload = Keeper_event_queue.Bootstrap
  }
;;

let enqueue ~base_path ~keeper_name post_id =
  match
    Keeper_event_queue_persistence.enqueue_stimulus_if_absent_result ~base_path ~keeper_name
      (stimulus post_id)
  with
  | Ok _ -> ()
  | Error detail -> failf "enqueue for %s: %s" keeper_name detail
;;

let with_base_path prefix f =
  let base_path = Unix.realpath (Filename.temp_dir prefix "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () -> f base_path)
;;

let test_the_hooks_name_the_workspace_and_keeper () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_base_path "keeper-event-queue-hooks-" @@ fun base_path ->
  let heard = ref [] in
  let record ~base_path ~keeper_name = heard := (base_path, keeper_name) :: !heard in
  Keeper_event_queue_persistence.install_state_change_observer record;
  Keeper_reaction_ledger.install_state_change_observer record;
  Fun.protect
    ~finally:(fun () ->
      Keeper_event_queue_persistence.install_state_change_observer ignore_writes;
      Keeper_reaction_ledger.install_state_change_observer ignore_writes)
    (fun () ->
      enqueue ~base_path ~keeper_name:"alpha" "queue-hook";
      check bool "a queue write names its workspace and Keeper" true
        (List.mem (base_path, "alpha") !heard);
      check bool "and no other Keeper" false
        (List.exists (fun (_, keeper_name) -> not (String.equal keeper_name "alpha")) !heard);
      heard := [];
      Keeper_reaction_ledger.record_event_queue_stimulus ~base_path ~keeper_name:"beta"
        (stimulus "ledger-hook");
      check (list (pair string string)) "a reaction row names its workspace and Keeper"
        [ base_path, "beta" ] !heard)
;;

let test_each_changed_keeper_is_announced () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  with_base_path "keeper-event-queue-announce-" @@ fun base_path ->
  Fun.protect
    ~finally:(fun () ->
      Keeper_event_queue_persistence.install_state_change_observer ignore_writes;
      Keeper_reaction_ledger.install_state_change_observer ignore_writes)
    (fun () ->
      ignore (Workspace.init (Workspace.default_config base_path) ~agent_name:None);
      let heard = Eio.Stream.create max_int in
      let id = "keeper-event-queue-announce" in
      Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
        ~callback:(fun (event : Sse.external_event) ->
          match
            ( Json_util.assoc_string_opt "type" event.ext_payload
            , Json_util.assoc_string_opt "keeper" event.ext_payload )
          with
          | Some kind, Some keeper_name
            when String.equal kind Keeper_event_queue_changed_event.event_type ->
            Eio.Stream.add heard keeper_name
          | (Some _ | None), (Some _ | None) -> ())
        ();
      Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
        Eio.Switch.run @@ fun sw ->
        Server_keeper_event_queue_broadcast.install ~sw;
        let expect label keeper_name =
          match
            Eio.Time.with_timeout clock signal_wait_s (fun () -> Ok (Eio.Stream.take heard))
          with
          | Ok announced -> check string label keeper_name announced
          | Error `Timeout -> failf "%s: no announcement" label
        in
        enqueue ~base_path ~keeper_name:"alpha" "announce-queue";
        expect "a queue write announces its Keeper" "alpha";
        Keeper_reaction_ledger.record_event_queue_stimulus ~base_path ~keeper_name:"beta"
          (stimulus "announce-ledger");
        expect "a reaction row announces its Keeper" "beta"))
;;

let () =
  run "keeper_event_queue_announce"
    [ ( "announce"
      , [ test_case "the hooks name the workspace and Keeper" `Quick
            test_the_hooks_name_the_workspace_and_keeper
        ; test_case "each changed Keeper is announced" `Quick
            test_each_changed_keeper_is_announced
        ] )
    ]
;;
