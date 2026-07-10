module Types = Masc.Keeper_memory_os_types
module Memory_io = Masc.Keeper_memory_os_io

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

let expect_invalid_argument label f =
  match f () with
  | () -> Alcotest.failf "%s: expected Invalid_argument" label
  | exception Invalid_argument _ -> ()
;;

let test_explicit_root_isolates_append_and_generation () =
  with_temp_roots (fun ~first ~second ->
    let keeper_id =
      Keeper_id.Keeper_name.of_string "explicit-root-keeper" |> Result.get_ok
    in
    let keeper_id_string = Keeper_id.Keeper_name.to_string keeper_id in
    let trace_id =
      Keeper_id.Trace_id.of_string "explicit-root-trace" |> Result.get_ok
    in
    let first_episode =
      episode
        ~trace_id:(Keeper_id.Trace_id.to_string trace_id)
        ~generation:0
        ~created_at:1_000.0
    in
    Memory_io.with_episode_bundle_lock_for_keepers_dir
      ~keepers_dir:first
      ~keeper_id
      (fun () ->
         Memory_io.append_episode_for_keepers_dir
           ~keepers_dir:first
           ~keeper_id
           first_episode;
         Memory_io.append_event_for_keepers_dir
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
    let trace_id =
      Keeper_id.Trace_id.of_string "explicit-retention-trace"
      |> Result.get_ok
    in
    let trace_id_string = Keeper_id.Trace_id.to_string trace_id in
    let existing =
      fact ~claim:"existing" ~trace_id:trace_id_string ~turn:0 ~observed_at:1.0
    in
    let incoming =
      fact ~claim:"incoming" ~trace_id:trace_id_string ~turn:1 ~observed_at:2.0
    in
    let stats =
      Memory_io.with_facts_lock_for_keepers_dir
        ~keepers_dir:first
        ~keeper_id
        ~on_timeout:Alcotest.fail
        (fun () ->
          Memory_io.rewrite_facts_atomically_for_keepers_dir
            ~keepers_dir:first
            ~keeper_id:keeper_id_string
            [ existing ];
          Memory_io.merge_and_cap_facts_for_keepers_dir
            ~keepers_dir:first
            ~now:3.0
            ~keeper_id
            ~merge:(fun ~existing:_ ~incoming -> incoming)
            ~incoming:[ incoming ]
            ~keep:2
            ~trigger:2
            ~rank:(fun persisted -> persisted.Types.first_seen))
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
    let event_dropped, episode_dropped =
      Memory_io.with_episode_bundle_lock_for_keepers_dir
        ~keepers_dir:first
        ~keeper_id
        (fun () ->
          List.iter
            (fun generation ->
              let persisted =
                episode
                  ~trace_id:trace_id_string
                  ~generation
                  ~created_at:(10.0 +. float_of_int generation)
              in
              Memory_io.append_episode_for_keepers_dir
                ~keepers_dir:first
                ~keeper_id
                persisted;
              Memory_io.append_event_for_keepers_dir
                ~keepers_dir:first
                ~keeper_id
                persisted)
            [ 0; 1; 2 ];
          ( Memory_io.cap_events_for_keepers_dir
              ~keepers_dir:first
              ~keeper_id
              ~keep:1
              ~trigger:2
          , Memory_io.cap_episode_files_for_keepers_dir
              ~keepers_dir:first
              ~keeper_id
              ~keep:1
              ~trigger:2 ))
    in
    Alcotest.(check int)
      "event cap reports removed rows"
      2
      event_dropped;
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
      episode_dropped;
    Alcotest.(check int)
      "episode cap retains one file"
      1
      (episode_file_count ~keepers_dir:first ~keeper_id))
;;

let test_invalid_episode_trace_is_rejected_before_io () =
  with_temp_roots (fun ~first ~second:_ ->
    let keeper_id =
      Keeper_id.Keeper_name.of_string "invalid-trace-keeper" |> Result.get_ok
    in
    let invalid_episode = episode ~trace_id:"../escape" ~generation:0 ~created_at:1.0 in
    expect_invalid_argument "invalid episode trace" (fun () ->
      Memory_io.append_episode_for_keepers_dir
        ~keepers_dir:first
        ~keeper_id
        invalid_episode);
    Alcotest.(check bool)
      "invalid trace creates no keeper directory"
      false
      (Sys.file_exists
         (Filename.concat first (Keeper_id.Keeper_name.to_string keeper_id))))
;;

let test_symlinked_episodes_directory_is_rejected () =
  with_temp_roots (fun ~first ~second ->
    let keeper_id =
      Keeper_id.Keeper_name.of_string "symlink-episodes-keeper" |> Result.get_ok
    in
    let keeper_dir =
      Filename.concat first (Keeper_id.Keeper_name.to_string keeper_id)
    in
    Unix.mkdir keeper_dir 0o700;
    let outside = Filename.concat second "outside-episodes" in
    Unix.mkdir outside 0o700;
    Unix.symlink outside (Filename.concat keeper_dir "episodes");
    let trace_id =
      Keeper_id.Trace_id.of_string "symlink-episodes-trace" |> Result.get_ok
    in
    expect_invalid_argument "symlinked episodes directory" (fun () ->
      Memory_io.append_episode_for_keepers_dir
        ~keepers_dir:first
        ~keeper_id
        (episode
           ~trace_id:(Keeper_id.Trace_id.to_string trace_id)
           ~generation:0
           ~created_at:1.0));
    Alcotest.(check (list string))
      "outside directory remains empty"
      []
      (Sys.readdir outside |> Array.to_list))
;;

let test_symlinked_events_file_is_rejected () =
  with_temp_roots (fun ~first ~second ->
    let keeper_id =
      Keeper_id.Keeper_name.of_string "symlink-events-keeper" |> Result.get_ok
    in
    let keeper_id_string = Keeper_id.Keeper_name.to_string keeper_id in
    let outside = Filename.concat second "outside-events.jsonl" in
    Fs_compat.save_file outside "sentinel\n";
    Unix.symlink
      outside
      (Memory_io.events_path_for_keepers_dir
         ~keepers_dir:first
         ~keeper_id:keeper_id_string);
    let trace_id =
      Keeper_id.Trace_id.of_string "symlink-events-trace" |> Result.get_ok
    in
    expect_invalid_argument "symlinked events file" (fun () ->
      Memory_io.append_event_for_keepers_dir
        ~keepers_dir:first
        ~keeper_id
        (episode
           ~trace_id:(Keeper_id.Trace_id.to_string trace_id)
           ~generation:0
           ~created_at:1.0));
    Alcotest.(check string)
      "outside file remains unchanged"
      "sentinel\n"
      (Fs_compat.load_file outside))
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
        ; Alcotest.test_case
            "invalid episode trace is rejected before I/O"
            `Quick
            test_invalid_episode_trace_is_rejected_before_io
        ; Alcotest.test_case
            "symlinked episodes directory is rejected"
            `Quick
            test_symlinked_episodes_directory_is_rejected
        ; Alcotest.test_case
            "symlinked events file is rejected"
            `Quick
            test_symlinked_events_file_is_rejected
        ] )
    ]
;;
