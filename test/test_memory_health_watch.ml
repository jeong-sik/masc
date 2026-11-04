(* The server keeps the Keeper memory health it computed and serves it, and
   announces each Keeper whose row moved, appeared or left. *)

open Alcotest
open Masc

let row keeper facts = `Assoc [ "keeper_id", `String keeper; "facts", `Int facts ]

let health ?(execution = `List []) ?(generated_at = 1.0) rows =
  `Assoc
    [ "generated_at", `Float generated_at
    ; "execution", execution
    ; "keepers", `List rows
    ]

let test_only_moved_rows_are_announced () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "memory-health-watch-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    ignore (Workspace.init (Workspace.default_config base_path) ~agent_name:None);
    let heard = ref [] in
    let id = "memory-health-watch" in
    Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
      ~callback:(fun (event : Sse.external_event) ->
        match Json_util.assoc_string_opt "type" event.ext_payload, event.ext_payload with
        | Some kind, `Assoc fields when String.equal kind Workspace_dataset_event.event_type ->
          (match Workspace_dataset_event.of_fields fields with
           | Ok (Workspace_dataset_event.Memory_health { keeper }) -> heard := keeper :: !heard
           | Ok _ | Error _ -> ())
        | (Some _ | None), _ -> ())
      ();
    Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
      let take () = let got = List.sort String.compare !heard in heard := []; got in
      let observe = Server_memory_health_watch.observe ~base_path in
      observe (health [ row "a" 1; row "b" 1 ]);
      check (list string) "the first answer announces every row" [ "a"; "b" ] (take ());
      observe (health ~generated_at:2.0 [ row "a" 1; row "b" 1 ]);
      check (list string) "the time an answer was computed at is not a change" [] (take ());
      observe (health [ row "a" 2; row "b" 1 ]);
      check (list string) "a moved row is announced alone" [ "a" ] (take ());
      observe (health [ row "a" 2 ]);
      check (list string) "a Keeper that left is announced" [ "b" ] (take ());
      observe (health ~execution:(`List [ `String "serving" ]) [ row "a" 2 ]);
      check (list string) "the execution availability, which no reader draws, is not a change"
        [] (take ());
      let served () =
        match Server_memory_health_watch.latest ~base_path with
        | Some (Server_memory_health_watch.Computed json) -> Some json
        | Some (Server_memory_health_watch.Failed _) | None -> None
      in
      check bool "the last answer is served" true
        (Option.equal Yojson.Safe.equal
           (Some (health ~execution:(`List [ `String "serving" ]) [ row "a" 2 ]))
           (served ()));
      Server_memory_health_watch.observe ~base_path:"/elsewhere" (health []);
      observe (health [ row "a" 2 ]);
      check (list string) "another workspace's answer does not replace this one's" [] (take ());
      let computed = Server_memory_health_watch.compute ~base_path in
      (match computed, Server_memory_health_watch.latest ~base_path with
       | Server_memory_health_watch.Computed json, Some (Server_memory_health_watch.Computed kept) ->
         check bool "a computed answer is the one kept" true (Yojson.Safe.equal json kept)
       | Server_memory_health_watch.Failed detail, _ -> fail ("the computation failed: " ^ detail)
       | Server_memory_health_watch.Computed _, (Some (Server_memory_health_watch.Failed _) | None) ->
         fail "the computed answer was not kept")))

let () =
  run "memory_health_watch"
    [ ( "announce"
      , [ test_case "only moved rows are announced" `Quick test_only_moved_rows_are_announced ] )
    ]
