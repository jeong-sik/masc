(* RFC-0480 §3.4: a Keeper's metrics file tells its workspace's readers when
   it gains a row. *)

open Alcotest
open Masc

let listen ~base_path ~id heard =
  Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
    ~callback:(fun (event : Sse.external_event) ->
      match Json_util.assoc_string_opt "type" event.ext_payload with
      | Some kind when String.equal kind Keeper_metrics_broadcast.appended_event ->
        heard := Json_util.assoc_string_opt "name" event.ext_payload :: !heard
      | Some _ | None -> ())
    ()
;;

let test_append_announces_the_keeper () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "keeper-metrics-announce-" "") in
  let other_path = Unix.realpath (Filename.temp_dir "keeper-metrics-other-" "") in
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.remove_tree base_path;
      Fs_compat.remove_tree other_path)
    (fun () ->
      let config = Workspace.default_config base_path in
      ignore (Workspace.init config ~agent_name:None);
      ignore (Workspace.init (Workspace.default_config other_path) ~agent_name:None);
      let heard = ref [] in
      let other_heard = ref [] in
      listen ~base_path ~id:"keeper-metrics-announce" heard;
      listen ~base_path:other_path ~id:"keeper-metrics-other" other_heard;
      Fun.protect
        ~finally:(fun () ->
          Sse.unsubscribe_external "keeper-metrics-announce";
          Sse.unsubscribe_external "keeper-metrics-other")
        (fun () ->
          Keeper_types_support.append_keeper_metrics config "announce-keeper"
            (`Assoc [ "channel", `String "heartbeat"; "name", `String "announce-keeper" ]);
          check (list (option string)) "the row announces its Keeper"
            [ Some "announce-keeper" ] !heard;
          Keeper_types_support.append_keeper_metrics config "announce-keeper"
            (`Assoc [ "channel", `String "turn"; "name", `String "announce-keeper" ]);
          check int "each row announces" 2 (List.length !heard);
          check (list (option string)) "another workspace hears nothing" [] !other_heard))
;;

let () =
  run "keeper_metrics_appended_announce"
    [ ( "store"
      , [ test_case "an appended row announces its Keeper" `Quick
            test_append_announces_the_keeper
        ] )
    ]
;;
