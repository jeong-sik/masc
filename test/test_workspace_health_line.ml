(* The Home Health line is taken from the mission briefing: the health word,
   the Keeper listing, and how many Keepers have a state no one can read. A
   mission recomputation announces [workspace_health] when its line differs
   from the last one, and nothing when it is the same. *)

open Alcotest
open Masc

let listed = `Assoc [ "state", `String "listed" ]

let briefing ?(health = "ok") ?(unread = []) briefs =
  `Assoc
    [ "summary", `Assoc [ "workspace_health", `String health ]
    ; "keepers_listing", listed
    ; "keepers_unread", `List unread
    ; "keeper_briefs", `List briefs
    ]

let brief status = `Assoc [ "name", `String "k"; "status", status ]

let test_the_line_counts_unreadable_keepers () =
  let json =
    briefing
      ~unread:[ `Assoc [ "name", `String "lost" ] ]
      [ brief (`String "active"); brief (`String "paused"); brief (`String "no-such-word")
      ; `Assoc [ "name", `String "silent" ]
      ]
  in
  check
    string
    "an unread Keeper, an unknown word and a missing word are unreadable"
    (Yojson.Safe.to_string
       (`Assoc
         [ "workspace_health", `String "ok"
         ; "keepers_listing", listed
         ; "unreadable_keepers", `Int 3
         ]))
    (Yojson.Safe.to_string (Server_workspace_health_line.of_briefing json))

let has_error json =
  match json with
  | `Assoc fields -> List.mem_assoc "error" fields
  | _ -> false

let test_a_briefing_without_the_fields_is_an_error () =
  check bool "no summary" true
    (has_error (Server_workspace_health_line.of_briefing (`Assoc [])));
  check bool "no keepers_unread list" true
    (has_error
       (Server_workspace_health_line.of_briefing
          (`Assoc
            [ "summary", `Assoc [ "workspace_health", `String "ok" ]
            ; "keepers_listing", listed
            ])))

let test_the_line_fields_match_wire_contract () =
  let line =
    Server_workspace_health_line.of_briefing
      (briefing ~health:"warning" [ brief (`String "no-such-word") ])
  in
  check (option string) "the health word" (Some "warning")
    (Json_util.assoc_string_opt "workspace_health" line);
  check (option string) "the listing state" (Some "listed")
    (match Yojson.Safe.Util.member "keepers_listing" line with
     | `Assoc _ as obj -> Json_util.assoc_string_opt "state" obj
     | _ -> None);
  check (option int) "the unreadable count" (Some 1)
    (Json_util.assoc_int_opt "unreadable_keepers" line)

let test_only_a_moved_line_is_announced () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "workspace-health-line-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    ignore (Workspace.init (Workspace.default_config base_path) ~agent_name:None);
    let heard = ref 0 in
    let id = "workspace-health-line" in
    let name = Workspace_dataset_event.dataset_name Workspace_dataset_event.Workspace_health in
    Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
      ~callback:(fun (event : Sse.external_event) ->
        match
          ( Json_util.assoc_string_opt "type" event.ext_payload
          , Json_util.assoc_string_opt "dataset" event.ext_payload )
        with
        | Some kind, Some dataset
          when String.equal kind Workspace_dataset_event.event_type
               && String.equal dataset name -> incr heard
        | (Some _ | None), (Some _ | None) -> ())
      ();
    Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
      let observe json = Server_workspace_health_line.observe ~base_path json in
      observe (briefing [ brief (`String "active") ]);
      check int "the first line is announced" 1 !heard;
      (* A Keeper's name or a field the line does not carry changing is the
         same line. *)
      observe (briefing [ `Assoc [ "name", `String "other"; "status", `String "idle" ] ]);
      check int "the same line is not announced" 1 !heard;
      observe (briefing ~health:"warning" [ brief (`String "active") ]);
      check int "a moved health word is announced" 2 !heard;
      observe (briefing ~health:"warning" [ brief (`String "no-such-word") ]);
      check int "a moved unreadable count is announced" 3 !heard))

let () =
  run "workspace_health_line"
    [ ( "line"
      , [ test_case "the line counts unreadable Keepers" `Quick
            test_the_line_counts_unreadable_keepers
        ; test_case "a briefing without the fields is an error" `Quick
            test_a_briefing_without_the_fields_is_an_error
        ] )
    ; ( "wire"
      , [ test_case "the line carries health, listing and unreadable count" `Quick
            test_the_line_fields_match_wire_contract
        ] )
    ; ( "announce"
      , [ test_case "only a moved line is announced" `Quick test_only_a_moved_line_is_announced ] )
    ]
