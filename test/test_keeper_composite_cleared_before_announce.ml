(** The Keeper's composite read models are dropped before
    [keeper_composite_changed] goes out, so a reader that fetches on the
    event computes them again instead of being served the cached ones. *)

open Masc
module Keys = Server_dashboard_http_keeper_api_types

let temp_dir () =
  let dir = Filename.temp_file "composite-cleared-" ".dir" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  dir
;;

let is_composite_changed frame =
  match Sse.data_payload_of_frame frame with
  | Error Sse.Missing_data_payload -> false
  | Ok payload ->
    (match Yojson.Safe.from_string payload with
     | `Assoc fields ->
       List.assoc_opt "type" fields = Some (`String "keeper_composite_changed")
     | _ -> false
     | exception Yojson.Json_error _ -> false)
;;

let test_caches_are_empty_when_the_event_is_heard () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let keeper_key = Keys.keeper_composite_cache_key ~base_path "alpha" in
  let other_key = Keys.keeper_composite_cache_key ~base_path "beta" in
  let fleet_key = Keys.fleet_composite_cache_key ~base_path in
  let subscriber_id = Printf.sprintf "composite-cleared-%d" (Unix.getpid ()) in
  Fun.protect
    ~finally:(fun () ->
      Sse.unsubscribe_external subscriber_id;
      List.iter Dashboard_cache.invalidate [ keeper_key; other_key; fleet_key ];
      Fs_compat.remove_tree base_path)
    (fun () ->
       Keeper_registry_broadcast.install_before_composite_changed
         Keys.invalidate_keeper_composite_caches;
       List.iter
         (fun key -> Dashboard_cache.seed_stale_if_missing key ~stale_for:60.0 (`String "cached"))
         [ keeper_key; other_key; fleet_key ];
       Alcotest.(check bool) "the caches hold values before the change" true
         (List.for_all
            (fun key -> Option.is_some (Dashboard_cache.peek key))
            [ keeper_key; other_key; fleet_key ]);
       let heard = ref [] in
       Sse.subscribe_external
         ~runtime_authority:(Sse.runtime_authority_exn ~base_path)
         ~id:subscriber_id
         ~callback:(fun (ev : Sse.external_event) ->
           if is_composite_changed ev.Sse.ext_frame
           then
             heard :=
               (Dashboard_cache.peek keeper_key, Dashboard_cache.peek fleet_key) :: !heard)
         ();
       Keeper_registry_broadcast.composite_changed ~base_path ~name:"alpha" ~ts_unix:1.0;
       (match !heard with
        | [ (keeper, fleet) ] ->
          Alcotest.(check bool) "the Keeper's composite is gone when the event is heard"
            true (Option.is_none keeper);
          Alcotest.(check bool) "the fleet composite is gone when the event is heard"
            true (Option.is_none fleet)
        | heard -> Alcotest.failf "expected one composite event, heard %d" (List.length heard));
       Alcotest.(check bool) "another Keeper's composite stays" true
         (Option.is_some (Dashboard_cache.peek other_key)))
;;

let () =
  Alcotest.run "keeper_composite_cleared_before_announce"
    [ ( "composite"
      , [ Alcotest.test_case "caches are empty when the event is heard" `Quick
            test_caches_are_empty_when_the_event_is_heard
        ] )
    ]
;;
