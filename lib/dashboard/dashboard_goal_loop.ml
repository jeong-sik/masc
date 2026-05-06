let concat3 a b c = Filename.concat (Filename.concat a b) c

let status_path_candidates ~base_path =
  let masc_dir = Common.masc_dir_from_base_path ~base_path in
  [
    concat3 masc_dir "goal-loop" "status.json";
    concat3 masc_dir "goal_loop" "status.json";
    concat3 base_path "goal-loop" "status.json";
  ]

let dashboard_source_json kind fields =
  `Assoc (("kind", `String kind) :: fields)

let add_dashboard_source json source =
  match json with
  | `Assoc fields ->
      let fields =
        List.filter (fun (key, _) -> not (String.equal key "dashboard_source")) fields
      in
      `Assoc (("dashboard_source", source) :: fields)
  | _ -> json

let unknown_phase reason =
  `Assoc
    [
      ("status", `String "unknown");
      ("summary", `Assoc [ ("reason", `String reason) ]);
    ]

let known_corpus_blocker_json =
  `Assoc
    [
      ("id", `String "strict_row_level_catalog_complete");
      ("status", `String "BLOCKED");
      ("issue", `String "#13265");
      ("description", `String "strict 206-row audit corpus remains incomplete");
    ]

let fallback_status_json ~overall_status ~source ~reason =
  `Assoc
    [
      ("schema_version", `Int 1);
      ("generated_at", `String (Keeper_types.now_iso ()));
      ("loop_iteration", `String "unknown");
      ("overall_status", `String overall_status);
      ( "phases",
        `Assoc
          [
            ("observe", unknown_phase reason);
            ("orient", unknown_phase reason);
            ("decide", unknown_phase reason);
            ("act", unknown_phase reason);
            ("verify", unknown_phase reason);
          ] );
      ("next_action", `Null);
      ("system_health_signals", `Assoc []);
      ("dashboard_source", source);
      ("known_blockers", `List [ known_corpus_blocker_json ]);
    ]

let missing_status_json ~base_path =
  let candidates = status_path_candidates ~base_path in
  let source =
    dashboard_source_json "runtime_status_missing"
      [
        ( "status_path_candidates",
          `List (List.map (fun path -> `String path) candidates) );
      ]
  in
  fallback_status_json ~overall_status:"unknown" ~source
    ~reason:"runtime_status_json_missing"

let invalid_status_json ~path ~error =
  let source =
    dashboard_source_json "runtime_status_invalid"
      [ ("path", `String path); ("error", `String error) ]
  in
  fallback_status_json ~overall_status:"critical" ~source
    ~reason:"runtime_status_json_invalid"

let first_existing_path paths =
  List.find_opt Fs_compat.file_exists paths

let status_json ~base_path () =
  match first_existing_path (status_path_candidates ~base_path) with
  | None -> missing_status_json ~base_path
  | Some path -> (
      try
        let json = Yojson.Safe.from_string (Fs_compat.load_file path) in
        match json with
        | `Assoc _ ->
            add_dashboard_source json
              (dashboard_source_json "runtime_status_json" [ ("path", `String path) ])
        | _ -> invalid_status_json ~path ~error:"expected JSON object"
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> invalid_status_json ~path ~error:(Printexc.to_string exn))
