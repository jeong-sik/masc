(* The Lanes inventory is compared on the server's clock. Two captures of the
   same registries and configuration draw the same value, the times they were
   taken at aside, and only a drawing that moved announces [lanes]. *)

open Alcotest
open Masc

module Projection = Server_standalone_lane_projection

let has key json = not (Yojson.Safe.equal (Yojson.Safe.Util.member key json) `Null)

let test_two_captures_draw_the_same_value () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let first = Projection.observe () in
  let second = Projection.observe () in
  check bool "unchanged inputs draw the same value" true
    (Yojson.Safe.equal (Projection.observation_drawn_json first)
       (Projection.observation_drawn_json second));
  let served = Projection.observation_to_json first in
  let drawn = Projection.observation_drawn_json first in
  check bool "the served snapshot says when it was taken" true
    (has "generated_at" served && has "observed_at_unix" served);
  check bool "the drawing leaves the times out" false
    (has "generated_at" drawn || has "observed_at_unix" drawn);
  check bool "the drawing keeps the lanes" true (has "lanes" drawn)

let drawing lanes = `Assoc [ "schema", `String "masc.lane-inventory/v1"; "rows", `List lanes ]

let test_only_a_moved_drawing_is_announced () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "lane-inventory-watch-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    ignore (Workspace.init (Workspace.default_config base_path) ~agent_name:None);
    let heard = ref 0 in
    let id = "lane-inventory-watch" in
    (* The event is read back the way the TUI reads it. *)
    Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
      ~callback:(fun (event : Sse.external_event) ->
        match Json_util.assoc_string_opt "type" event.ext_payload, event.ext_payload with
        | Some kind, `Assoc fields when String.equal kind Workspace_dataset_event.event_type ->
          (match Workspace_dataset_event.of_fields fields with
           | Ok Workspace_dataset_event.Lanes -> incr heard
           | Ok _ | Error _ -> ())
        | (Some _ | None), _ -> ())
      ();
    Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
      let observe = Server_lane_inventory_watch.observe ~base_path in
      observe (drawing [ `String "librarian" ]);
      check int "the first drawing is announced" 1 !heard;
      observe (drawing [ `String "librarian" ]);
      check int "the same drawing is not announced" 1 !heard;
      observe (drawing [ `String "librarian"; `String "verifier" ]);
      check int "a moved drawing is announced" 2 !heard;
      Server_lane_inventory_watch.observe ~base_path:"/elsewhere" (drawing []);
      check int "another workspace's drawing is not announced here" 2 !heard;
      observe (drawing [ `String "librarian"; `String "verifier" ]);
      check int "another workspace's drawing does not replace this one's last" 2 !heard))

let () =
  run "lane_inventory_watch"
    [ ( "drawing"
      , [ test_case "two captures draw the same value" `Quick
            test_two_captures_draw_the_same_value
        ] )
    ; ( "announce"
      , [ test_case "only a moved drawing is announced" `Quick
            test_only_a_moved_drawing_is_announced
        ] )
    ]
