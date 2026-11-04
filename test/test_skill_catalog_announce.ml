(* RFC-0480 §3.4: the server's skill catalog publication observer drops the
   full-health snapshot and tells the workspace's readers. That the service
   calls the observer on every publication, and only then, is
   test_skill_catalog_snapshot_service's "publication observer" case. *)

open Alcotest
open Masc

let test_the_observer_invalidates_health_and_announces () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "skill-catalog-announce-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    ignore (Workspace.init (Workspace.default_config base_path) ~agent_name:None);
    let heard = ref 0 in
    let health_dropped_before = ref [] in
    let health_dropped = ref 0 in
    let id = "skill-catalog-announce" in
    Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
      ~callback:(fun (event : Sse.external_event) ->
        match Json_util.assoc_string_opt "type" event.ext_payload with
        | Some kind when String.equal kind Skill_catalog_published_event.event_type ->
          incr heard;
          health_dropped_before := !health_dropped :: !health_dropped_before
        | Some _ | None -> ())
      ();
    Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
      let observe =
        Server_skill_catalog_broadcast.publication_observer ~base_path
          ~invalidate_full_health:(fun () -> incr health_dropped)
      in
      observe ();
      check int "a publication announces once" 1 !heard;
      check (list int) "health was dropped before the announcement" [ 1 ]
        !health_dropped_before))
;;

let () =
  run "skill_catalog_announce"
    [ ( "publication"
      , [ test_case "the observer invalidates health and announces" `Quick
            test_the_observer_invalidates_health_and_announces ] )
    ]
;;
