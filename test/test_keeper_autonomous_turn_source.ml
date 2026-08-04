(** Guards for [Keeper_autonomous_turn_source], the dashboard's only reader
    of the per-turn raw-trace store.

    The store holds both turn kinds — [Keeper_turn] runs a direct
    [masc_keeper_msg] turn through the same [Keeper_agent_run.run_turn] the
    autonomous cycle uses — and a direct turn is already persisted in the
    keeper chat store. Emitting it here too would render it twice in the
    dashboard transcript, so exclusion is the load-bearing property.

    The reader also runs on the dashboard chat read path, so a corrupt or
    truncated turn file must degrade to a skip, never an exception. *)

open Masc

let keeper_name = "keeper-autonomous-source"

let temp_dir () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_autonomous_turn_source_%d_%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path
        |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
  in
  rm dir

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
      f (Workspace.default_config dir))

(* [keeper_raw_trace_dir] derives a path without touching the filesystem, so
   fixtures create the tree the writer would have created. *)
let ensure_trace_dir config =
  let dir = Keeper_types_support.keeper_raw_trace_dir config keeper_name in
  let rec mkdir_p path =
    if not (Sys.file_exists path) then begin
      mkdir_p (Filename.dirname path);
      try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  mkdir_p dir;
  dir

let record ~seq ~ts ~record_type fields =
  `Assoc
    (("trace_version", `Int Agent_sdk.Raw_trace.trace_version)
     :: ("worker_run_id", `String "wr-test-0000")
     :: ("seq", `Int seq)
     :: ("ts", `Float ts)
     :: ("agent_name", `String "test-agent")
     :: ("session_id", `String "trace-test-0000")
     :: ( "record_type",
          `String (Agent_sdk.Raw_trace.record_type_to_string record_type) )
     :: fields)

let run_started ~seq ~ts ~prompt =
  record ~seq ~ts ~record_type:Agent_sdk.Raw_trace.Run_started
    [ ("prompt", `String prompt); ("model", `String "test-model") ]

let assistant_block ~seq ~ts ~kind ~body =
  record ~seq ~ts ~record_type:Agent_sdk.Raw_trace.Assistant_block
    [ ("block_index", `Int seq); ("block_kind", `String kind);
      ("assistant_block", body) ]

let thinking_block ~seq ~ts ~text =
  assistant_block ~seq ~ts ~kind:"thinking"
    ~body:(`Assoc [ ("type", `String "thinking"); ("thinking", `String text) ])

let text_block ~seq ~ts ~text =
  assistant_block ~seq ~ts ~kind:"text"
    ~body:(`Assoc [ ("type", `String "text"); ("text", `String text) ])

(* Field set mirrors a live record: OAS decodes [tool_execution_started]
   strictly and rejects one missing [tool_execution_mode], so these literals
   also pin the wire shape the reader is built against. *)
let tool_started ~seq ~ts ~name ~input =
  record ~seq ~ts ~record_type:Agent_sdk.Raw_trace.Tool_execution_started
    [ ("tool_name", `String name); ("tool_input", input);
      ("tool_use_id", `String "toolu_test"); ("tool_turn", `Int 1);
      ("tool_planned_index", `Int 0); ("tool_batch_index", `Int 0);
      ("tool_batch_size", `Int 1);
      ("tool_execution_mode", `String "serial") ]

let run_finished ~seq ~ts ~final_text =
  record ~seq ~ts ~record_type:Agent_sdk.Raw_trace.Run_finished
    [ ("final_text", `String final_text); ("stop_reason", `String "end_turn") ]

let write_turn_file ~dir ~name lines =
  let path = Filename.concat dir name in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () ->
      List.iter
        (fun line -> output_string oc (line ^ "\n"))
        (List.map Yojson.Safe.to_string lines))

let turn_file_name index =
  Printf.sprintf "turn-%013d-0000-%06d.jsonl" (1_000_000 + index) index

let block_label (block : Keeper_autonomous_turn_source.block) =
  match block with
  | Keeper_autonomous_turn_source.Thinking text -> "thinking:" ^ text
  | Keeper_autonomous_turn_source.Text text -> "text:" ^ text
  | Keeper_autonomous_turn_source.Tool_use { name; _ } -> "tool:" ^ name

let wake_turn_lines ~base_ts ~text =
  [ run_started ~seq:1 ~ts:base_ts
      ~prompt:Keeper_unified_prompt.autonomous_wake_marker;
    thinking_block ~seq:2 ~ts:(base_ts +. 1.) ~text:"weighing the board";
    tool_started ~seq:3 ~ts:(base_ts +. 2.) ~name:"Read"
      ~input:(`Assoc [ ("path", `String "x.ml") ]);
    text_block ~seq:4 ~ts:(base_ts +. 3.) ~text;
    run_finished ~seq:5 ~ts:(base_ts +. 4.) ~final_text:text ]

let test_projects_autonomous_turn () =
  with_workspace @@ fun config ->
  let dir = ensure_trace_dir config in
  write_turn_file ~dir ~name:(turn_file_name 0)
    (wake_turn_lines ~base_ts:1000. ~text:"no work this cycle");
  match Keeper_autonomous_turn_source.load_recent ~config ~keeper_name () with
  | [ turn ] ->
      Alcotest.(check (list string))
        "thinking, tool call, and text survive in recorded order"
        [ "thinking:weighing the board"; "tool:Read"; "text:no work this cycle" ]
        (List.map block_label turn.blocks);
      Alcotest.(check (option string))
        "terminal text" (Some "no work this cycle") turn.final_text;
      Alcotest.(check (float 0.001)) "start timestamp" 1000. turn.started_at
  | turns ->
      Alcotest.failf "expected exactly one projected turn, got %d"
        (List.length turns)

let test_excludes_direct_turn () =
  with_workspace @@ fun config ->
  let dir = ensure_trace_dir config in
  write_turn_file ~dir ~name:(turn_file_name 0)
    [ run_started ~seq:1 ~ts:2000. ~prompt:"오늘 PR 상태 정리해줘";
      text_block ~seq:2 ~ts:2001. ~text:"3건 확인했습니다";
      run_finished ~seq:3 ~ts:2002. ~final_text:"3건 확인했습니다" ];
  Alcotest.(check int)
    "a direct turn is left to the chat store, never duplicated here" 0
    (List.length
       (Keeper_autonomous_turn_source.load_recent ~config ~keeper_name ()))

let test_missing_directory_is_empty () =
  with_workspace @@ fun config ->
  Alcotest.(check int)
    "a keeper that has never run traces yields no turns" 0
    (List.length
       (Keeper_autonomous_turn_source.load_recent ~config ~keeper_name ()))

let test_corrupt_file_is_skipped () =
  with_workspace @@ fun config ->
  let dir = ensure_trace_dir config in
  let path = Filename.concat dir (turn_file_name 0) in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc "{not json\n");
  write_turn_file ~dir ~name:(turn_file_name 1)
    (wake_turn_lines ~base_ts:3000. ~text:"still readable");
  match Keeper_autonomous_turn_source.load_recent ~config ~keeper_name () with
  | [ turn ] ->
      Alcotest.(check (option string))
        "the intact turn still renders after a corrupt neighbour"
        (Some "still readable") turn.final_text
  | turns ->
      Alcotest.failf "expected the intact turn only, got %d"
        (List.length turns)

let test_since_drops_older_turns () =
  with_workspace @@ fun config ->
  let dir = ensure_trace_dir config in
  write_turn_file ~dir ~name:(turn_file_name 0)
    (wake_turn_lines ~base_ts:1000. ~text:"older");
  write_turn_file ~dir ~name:(turn_file_name 1)
    (wake_turn_lines ~base_ts:5000. ~text:"newer");
  let turns =
    Keeper_autonomous_turn_source.load_recent ~config ~keeper_name ~since:2000.
      ()
  in
  Alcotest.(check (list (option string)))
    "only turns started after the cutoff" [ Some "newer" ]
    (List.map (fun (turn : Keeper_autonomous_turn_source.turn) ->
         turn.final_text)
       turns)

let test_limit_keeps_newest_turns () =
  with_workspace @@ fun config ->
  let dir = ensure_trace_dir config in
  write_turn_file ~dir ~name:(turn_file_name 0)
    (wake_turn_lines ~base_ts:1000. ~text:"oldest");
  write_turn_file ~dir ~name:(turn_file_name 1)
    (wake_turn_lines ~base_ts:2000. ~text:"newest");
  let turns =
    Keeper_autonomous_turn_source.load_recent ~config ~keeper_name ~limit:1 ()
  in
  Alcotest.(check (list (option string)))
    "the limit window is the newest files, not the oldest" [ Some "newest" ]
    (List.map (fun (turn : Keeper_autonomous_turn_source.turn) ->
         turn.final_text)
       turns)

let () =
  Alcotest.run "keeper_autonomous_turn_source"
    [ ( "load_recent",
        [ Alcotest.test_case "projects an autonomous turn" `Quick
            test_projects_autonomous_turn;
          Alcotest.test_case "excludes a direct turn" `Quick
            test_excludes_direct_turn;
          Alcotest.test_case "missing directory yields no turns" `Quick
            test_missing_directory_is_empty;
          Alcotest.test_case "skips a corrupt turn file" `Quick
            test_corrupt_file_is_skipped;
          Alcotest.test_case "since drops older turns" `Quick
            test_since_drops_older_turns;
          Alcotest.test_case "limit keeps the newest turns" `Quick
            test_limit_keeps_newest_turns ] ) ]
