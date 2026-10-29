open Alcotest
open Masc

(* The Keeper board scan replays the audience a post recorded when it was
   written. It does not read an address back out of the title and body.

   Each post below is written through the real write path and then has its
   stored row edited, so that the recorded audience disagrees with what its own
   text would give. A scan that still read the text delivers to a different
   post set than the one asserted here. *)

module KBA = Keeper_board_audience

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

(* The Board store lives under [MASC_BASE_PATH]; pointing it at the workspace
   keeps its JSONL file inside the directory this test removes. *)
let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "keeper-board-recorded" "" in
  Unix.putenv "MASC_BASE_PATH" base_path;
  let config = Workspace.default_config base_path in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.clear ();
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      remove_tree base_path)
    (fun () ->
       ignore (Workspace.init config ~agent_name:None : string);
       Board_dispatch.reset_for_test ();
       Board.reset_global_for_test ();
       Board_dispatch.init_jsonl ();
       f config)
;;

let register_keeper config name =
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ])
    with
    | Ok meta -> meta
    | Error detail -> fail detail
  in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path
  in
  Fs_compat.mkdir_p keepers_dir;
  Out_channel.with_open_text (Filename.concat keepers_dir (name ^ ".toml")) (fun oc ->
    output_string
      oc
      "[keeper]\n\
       instructions = \"Review Board evidence.\"\n\
       sandbox_profile = \"docker\"\n\
       sandbox_image = \"base\"\n");
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> fail detail);
  let resolved =
    match Keeper_meta_store.read_effective_meta config name with
    | Ok (Some resolved) -> resolved
    | Ok None -> fail "configured Keeper metadata missing"
    | Error detail -> fail detail
  in
  ignore
    (Keeper_registry.For_testing.register
       ~base_path:config.Workspace.base_path
       resolved.Keeper_meta_contract.name
       resolved);
  resolved
;;

let get = function
  | Ok value -> value
  | Error error -> fail (Board.show_board_error error)
;;

let post_id (post : Board.post) = Board.Post_id.to_string post.id

(* Rewrites the stored row of each listed post so that it records the given
   audience wire (none for [None]), then reloads the store from the file. *)
let record_audiences edits =
  let path = Board.persist_path () in
  let rows =
    In_channel.with_open_text path In_channel.input_all
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
  in
  let edited row =
    match Yojson.Safe.from_string row with
    | `Assoc fields ->
      (match List.assoc_opt "id" fields with
       | Some (`String id) ->
         (match List.assoc_opt id edits with
          | None -> row
          | Some audience ->
            let others = List.remove_assoc "audience" fields in
            let fields =
              match audience with
              | Some audience -> ("audience", audience) :: others
              | None -> others
            in
            Yojson.Safe.to_string (`Assoc fields))
       | _ -> row)
    | _ -> fail "a stored post row is not a JSON object"
  in
  Out_channel.with_open_text path (fun oc ->
    List.iter (fun row -> output_string oc (edited row ^ "\n")) rows);
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ()
;;

let targets_wire names =
  `Assoc [ "kind", `String "targets"; "targets", `List (List.map (fun n -> `String n) names) ]
;;

let board_event_failures () =
  Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string ObservationQueryFailures)
    ~labels:[ "operation", Runtime_observation_query_operation.(to_label Board_events) ]
    ()
;;

let queued_post_ids config name =
  match
    Keeper_registry_event_queue.snapshot_result ~base_path:config.Workspace.base_path name
  with
  | Ok queue ->
    Keeper_event_queue.to_list queue
    |> List.map (fun (stimulus : Keeper_event_queue.stimulus) -> stimulus.post_id)
  | Error detail -> fail detail
;;

let test_scan_follows_the_recorded_audience () =
  with_workspace
  @@ fun config ->
  let meta = register_keeper config "scanreader" in
  let create content =
    get
      (Board_dispatch.create_post
         ~author:"external-author"
         ~content
         ~title:"note"
         ~body:content
         ~visibility:Board.Internal
         ~post_kind:Board.Human_post
         ())
  in
  (* Text names nobody, record names the lane. *)
  let recorded_target = create "plain note" in
  (* Text names the lane, record is open to discovery. *)
  let recorded_open = create "@scanreader please look" in
  (* Text names the lane, row has no audience. *)
  let unrecorded = create "@scanreader older row" in
  record_audiences
    [ post_id recorded_target, Some (targets_wire [ "scanreader" ])
    ; post_id recorded_open, Some (`Assoc [ "kind", `String "discoverable" ])
    ; post_id unrecorded, None
    ];
  let audience_of post =
    KBA.of_post (get (Board_dispatch.get_post ~post_id:(post_id post)))
  in
  check
    bool
    "the edited rows reload with the audiences they were given"
    true
    (match audience_of recorded_target, audience_of recorded_open, audience_of unrecorded with
     | Ok (KBA.Targets [ _ ]), Ok KBA.Discoverable, Error KBA.Audience_not_recorded -> true
     | _ -> false);
  (* A cursor just past zero puts all three posts after it. *)
  Keeper_registry.set_board_cursor
    ~base_path:config.Workspace.base_path
    meta.Keeper_meta_contract.name
    1.0
    None;
  let failures_before = board_event_failures () in
  let _events, post_count, mention_count =
    Keeper_world_observation.collect_board_events
      ~base_path:config.Workspace.base_path
      ~meta
  in
  check int "all three posts are replayed" 3 post_count;
  check int "one delivery counts as a mention" 1 mention_count;
  check
    (list string)
    "only the post whose record names the lane is delivered"
    [ post_id recorded_target ]
    (queued_post_ids config meta.Keeper_meta_contract.name);
  check
    (float 0.)
    "the post without a recorded audience is counted as a failure"
    1.0
    (board_event_failures () -. failures_before)
;;

let () =
  run
    "keeper Board recorded audience"
    [ ( "scan"
      , [ test_case
            "follows the recorded audience, not the text"
            `Quick
            test_scan_follows_the_recorded_audience
        ] )
    ]
;;
