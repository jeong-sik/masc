module Types = Keeper_memory_os_types
module Memory_io = Keeper_memory_os_io

let with_temp_roots f =
  let root = Filename.temp_file "keeper-memory-explicit-root-" ".tmp" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let first = Filename.concat root "first" in
  let second = Filename.concat root "second" in
  Unix.mkdir first 0o700;
  Unix.mkdir second 0o700;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree root)
    (fun () -> f ~first ~second)
;;

let fact ~claim ~trace_id ~turn ~observed_at =
  { Types.claim
  ; category = Types.Fact
  ; external_ref = None
  ; claim_kind = Some Types.Durable_knowledge
  ; source = { Types.trace_id; turn; tool_call_id = None }
  ; observed_by = []
  ; first_seen = observed_at
  ; valid_until = None
  ; last_verified_at = Some observed_at
  ; schema_version = Types.schema_version
  ; claim_id = None
  }
;;

let episode ~trace_id ~generation ~created_at =
  { Types.trace_id
  ; generation
  ; episode_summary = Printf.sprintf "episode-%d" generation
  ; claims = []
  ; open_items = []
  ; constraints = []
  ; preserved_tool_refs = []
  ; source_turn_range = Some (generation, generation)
  ; created_at
  ; valid_until = None
  ; terminal_marker = None
  ; schema_version = Types.schema_version
  }
;;

let episode_file_count ~keepers_dir ~keeper_id =
  Memory_io.episodes_dir_for_keepers_dir ~keepers_dir ~keeper_id
  |> Sys.readdir
  |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".json")
  |> List.length
;;

let test_explicit_root_isolates_append_and_generation () =
  with_temp_roots (fun ~first ~second ->
    let keeper_id =
      Keeper_id.Keeper_name.of_string "explicit-root-keeper" |> Result.get_ok
    in
    let keeper_id_string = Keeper_id.Keeper_name.to_string keeper_id in
    let trace_id = "explicit-root-trace" in
    let first_episode = episode ~trace_id ~generation:0 ~created_at:1_000.0 in
    Memory_io.with_episode_bundle_lock_for_keepers_dir
      ~keepers_dir:first
      ~keeper_id
      (fun () ->
         Memory_io.append_event_for_keepers_dir
           ~keepers_dir:first
           ~keeper_id
           first_episode;
         Memory_io.append_episode_for_keepers_dir
           ~keepers_dir:first
           ~keeper_id
           first_episode);
    Alcotest.(check bool)
      "first root receives event"
      true
      (Sys.file_exists
         (Memory_io.events_path_for_keepers_dir
            ~keepers_dir:first
            ~keeper_id:keeper_id_string));
    Alcotest.(check bool)
      "second root remains untouched"
      false
      (Sys.file_exists
         (Memory_io.events_path_for_keepers_dir
            ~keepers_dir:second
            ~keeper_id:keeper_id_string));
    Alcotest.(check int)
      "episode written only to explicit root"
      1
      (episode_file_count ~keepers_dir:first ~keeper_id);
    Alcotest.(check int)
      "first generation starts at floor"
      4
      (Memory_io.next_generation_with_floor_for_keepers_dir
         ~keepers_dir:first
         ~floor:4
         ~keeper_id
         ~trace_id);
    Alcotest.(check int)
      "first generation advances"
      5
      (Memory_io.next_generation_with_floor_for_keepers_dir
         ~keepers_dir:first
         ~floor:0
         ~keeper_id
         ~trace_id);
    Alcotest.(check int)
      "second root has an independent counter"
      0
      (Memory_io.next_generation_with_floor_for_keepers_dir
         ~keepers_dir:second
         ~floor:0
         ~keeper_id
         ~trace_id))
;;

let test_explicit_root_scopes_merge_and_retention () =
  with_temp_roots (fun ~first ~second:_ ->
    let keeper_id =
      Keeper_id.Keeper_name.of_string "explicit-retention-keeper"
      |> Result.get_ok
    in
    let keeper_id_string = Keeper_id.Keeper_name.to_string keeper_id in
    let trace_id = "explicit-retention-trace" in
    let existing = fact ~claim:"existing" ~trace_id ~turn:0 ~observed_at:1.0 in
    let incoming = fact ~claim:"incoming" ~trace_id ~turn:1 ~observed_at:2.0 in
    Memory_io.rewrite_facts_atomically_for_keepers_dir
      ~keepers_dir:first
      ~keeper_id:keeper_id_string
      [ existing ];
    let stats =
      Memory_io.merge_and_cap_facts_for_keepers_dir
        ~keepers_dir:first
        ~now:3.0
        ~keeper_id
        ~merge:(fun ~existing:_ ~incoming -> incoming)
        ~incoming:[ incoming ]
        ~keep:2
        ~trigger:2
        ~rank:(fun persisted -> persisted.Types.first_seen)
    in
    Alcotest.(check int) "one fact appended" 1 stats.appended;
    Alcotest.(check int) "no fact merged" 0 stats.merged;
    Alcotest.(check int) "no fact dropped" 0 stats.dropped;
    (match
       Memory_io.read_facts_all_strict_for_keepers_dir
         ~keepers_dir:first
         ~keeper_id:keeper_id_string
     with
     | Ok persisted -> Alcotest.(check int) "two facts persisted" 2 (List.length persisted)
     | Error detail -> Alcotest.fail detail);
    List.iter
      (fun generation ->
         Memory_io.append_event_for_keepers_dir
           ~keepers_dir:first
           ~keeper_id
           (episode
              ~trace_id
              ~generation
              ~created_at:(10.0 +. float_of_int generation));
         Memory_io.append_episode_for_keepers_dir
           ~keepers_dir:first
           ~keeper_id
           (episode
              ~trace_id
              ~generation
              ~created_at:(10.0 +. float_of_int generation)))
      [ 0; 1; 2 ];
    Alcotest.(check int)
      "event cap reports removed rows"
      2
      (Memory_io.cap_events_for_keepers_dir
         ~keepers_dir:first
         ~keeper_id
         ~keep:1
         ~trigger:2);
    Alcotest.(check int)
      "event cap retains one row"
      1
      (Memory_io.events_path_for_keepers_dir
         ~keepers_dir:first
         ~keeper_id:keeper_id_string
       |> Fs_compat.load_jsonl
       |> List.length);
    Alcotest.(check int)
      "episode cap reports removed files"
      2
      (Memory_io.cap_episode_files_for_keepers_dir
         ~keepers_dir:first
         ~keeper_id
         ~keep:1
         ~trigger:2);
    Alcotest.(check int)
      "episode cap retains one file"
      1
      (episode_file_count ~keepers_dir:first ~keeper_id))
;;

let () =
  Alcotest.run
    "keeper_memory_os_explicit_root"
    [ ( "explicit-root"
      , [ Alcotest.test_case
            "append and generation are root-scoped"
            `Quick
            test_explicit_root_isolates_append_and_generation
        ; Alcotest.test_case
            "merge and retention are root-scoped"
            `Quick
            test_explicit_root_scopes_merge_and_retention
        ] )
    ]
;;
