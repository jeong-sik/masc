(** Tool_autoresearch_repo_synthesis — repo-synthesis-specific logic for
    the autoresearch swarm start handler. *)

open Tool_args

let default_repo_synthesis_roles =
  [
    "planner";
    "code-explorer";
    "doc-explorer";
    "test-explorer";
    "synthesizer";
    "reviewer";
  ]

let clamp_repo_synthesis_workers requested =
  requested |> max 1 |> min (List.length default_repo_synthesis_roles)

let repo_synthesis_planned_worker_roles ~max_workers =
  default_repo_synthesis_roles
  |> List.filteri (fun idx _ -> idx < clamp_repo_synthesis_workers max_workers)

let ensure_repo_synthesis_units config ~actor ~active_roster =
  let roster =
    List.sort_uniq String.compare
      (actor :: List.filter (fun value -> String.trim value <> "") active_roster)
  in
  let ensure_unit json =
    match Command_plane_v2.unit_update_json config ~actor json with
    | Ok _ -> Ok ()
    | Error message -> Error message
  in
  let company_id = "company-repo-synthesis" in
  let platoon_id = "platoon-repo-synthesis" in
  let base_unit_fields unit_id kind label parent_unit_id capability_profile =
    let parent_json =
      match parent_unit_id with
      | Some value -> [ ("parent_unit_id", `String value) ]
      | None -> []
    in
    `Assoc
      ([
         ("unit_id", `String unit_id);
         ("kind", `String kind);
         ("label", `String label);
         ("leader_id", `String actor);
         ("roster", `List (List.map (fun value -> `String value) roster));
         ( "capability_profile",
           `List (List.map (fun value -> `String value) capability_profile) );
       ]
      @ parent_json)
  in
  let units =
    [
      base_unit_fields company_id "company" "Repo Synthesis Company" None
        [ "repo_synthesis"; "coding_task"; "role:planner" ];
      base_unit_fields platoon_id "platoon" "Repo Synthesis Platoon"
        (Some company_id)
        [ "repo_synthesis"; "coding_task"; "role:planner" ];
      base_unit_fields "squad-code" "squad" "Code Evidence Squad"
        (Some platoon_id)
        [
          "repo_synthesis";
          "coding_task";
          "role:implementer";
          "artifact:lib/";
          "lang:ocaml";
          "tool:dune";
          "runtime:local64";
        ];
      base_unit_fields "squad-docs" "squad" "Docs Evidence Squad"
        (Some platoon_id)
        [
          "repo_synthesis";
          "coding_task";
          "role:librarian";
          "artifact:docs/";
          "runtime:local64";
        ];
      base_unit_fields "squad-tests" "squad" "Tests Evidence Squad"
        (Some platoon_id)
        [
          "repo_synthesis";
          "coding_task";
          "role:reviewer";
          "artifact:test/";
          "tool:dune";
          "runtime:local64";
        ];
      base_unit_fields "squad-review" "squad" "Synthesis Review Squad"
        (Some platoon_id)
        [
          "repo_synthesis";
          "coding_task";
          "role:reviewer";
          "artifact:docs/";
          "artifact:test/";
          "runtime:local64";
        ];
    ]
  in
  let rec loop = function
    | [] -> Ok company_id
    | json :: rest -> (
        match ensure_unit json with
        | Ok () -> loop rest
        | Error _ as error -> error)
  in
  loop units

let append_repo_synthesis_seed_event _config _session_id _detail =
  (* Team_session_store removed — no-op *)
  ()

let resolve_repo_synthesis_question ~repo_root ~question_id ~question ~artifact_scope =
  match question_id with
  | Some requested_id -> (
      match Repo_synthesis_benchmark.find_question_by_id ~repo_root requested_id with
      | Some matched ->
          let final_question =
            if String.trim question = "" then matched.question else question
          in
          let final_scope =
            if artifact_scope = [] then matched.artifact_scope else artifact_scope
          in
          (final_question, final_scope, Some requested_id, Some (Repo_synthesis_benchmark.default_question_set_path ~repo_root))
      | None ->
          ( question,
            artifact_scope,
            Some requested_id,
            Some (Repo_synthesis_benchmark.default_question_set_path ~repo_root) ))
  | None -> (question, artifact_scope, None, None)

type context = {
  base_path : string;
  agent_name : string option;
  start_operation : (goal:string -> target_file:string -> (Yojson.Safe.t, string) Stdlib.result) option;
  start_team_session :
    (goal:string ->
    operation_id:string option ->
    loop_id:string ->
    target_file:string ->
    program_note:string option ->
    (Yojson.Safe.t, string) Stdlib.result) option;
  config : Room.config option;
  sw : Eio.Switch.t option;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
}

let normalize_string_opt = function
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | None -> None

let parse_session_launch ctx json =
  let open Yojson.Safe.Util in
  let session_id = json |> member "session_id" |> to_string_option in
  match normalize_string_opt session_id with
  | None -> Error "team session launcher returned no session_id"
  | Some session_id ->
      let artifacts_dir =
        json |> member "artifacts_dir" |> to_string_option
        |> normalize_string_opt
        |> Option.value
             ~default:
               (Filename.concat ctx.base_path
                  (Filename.concat ".masc/team-sessions" session_id))
      in
      Ok (session_id, artifacts_dir)

let handle_repo_synthesis_swarm_start ctx args =
  match ctx.agent_name, ctx.config, ctx.sw, ctx.clock with
  | None, _, _, _ ->
      `Assoc
        [ ("error", `String "masc_repo_synthesis_swarm_start requires agent identity") ]
  | _, None, _, _ ->
      `Assoc
        [ ("error", `String "masc_repo_synthesis_swarm_start requires room config") ]
  | _, _, None, _ | _, _, _, None ->
      `Assoc
        [
          ( "error",
            `String
              "masc_repo_synthesis_swarm_start requires local team-session runtime context" );
        ]
  | Some agent_name, Some config, Some _sw, Some _clock ->
      let goal = get_string args "goal" "" |> String.trim in
      let question = get_string args "question" "" |> String.trim in
      let repo_root =
        get_string args "repo_root" ctx.base_path |> String.trim
      in
      if goal = "" then
        `Assoc [ ("error", `String "goal is required") ]
      else if question = "" then
        `Assoc [ ("error", `String "question is required") ]
      else if repo_root = "" then
        `Assoc [ ("error", `String "repo_root is required") ]
      else
        let question_id = normalize_string_opt (get_string_opt args "question_id") in
        let artifact_scope =
          get_string_list args "artifact_scope"
          |> List.filter (fun value -> String.trim value <> "")
        in
        let program_note = normalize_string_opt (get_string_opt args "program_note") in
        let model = normalize_string_opt (get_string_opt args "model") in
        let max_workers = get_int args "max_workers" 6 |> clamp_repo_synthesis_workers in
        let time_budget_sec = get_int args "time_budget_sec" 900 |> max 60 in
        let baseline_label = normalize_string_opt (get_string_opt args "baseline_label") in
        let resolved_question, resolved_scope, resolved_question_id, dataset_ref =
          resolve_repo_synthesis_question ~repo_root ~question_id ~question
            ~artifact_scope
        in
        Room.ensure_room_bootstrap config;
        let active_roster =
          (Room.read_state config).Types.active_agents
        in
        match ensure_repo_synthesis_units config ~actor:agent_name ~active_roster with
        | Error message -> `Assoc [ ("error", `String message) ]
        | Ok assigned_unit_id ->
            let operation_goal =
              Printf.sprintf "Repo synthesis: %s\nQuestion: %s" goal
                resolved_question
            in
            (match
               Command_plane_v2.start_operation config ~actor:agent_name
                 (`Assoc
                   [
                     ("assigned_unit_id", `String assigned_unit_id);
                     ("objective", `String operation_goal);
                     ("policy_class", `String "guarded");
                     ("budget_class", `String "standard");
                     ("workload_profile", `String "coding_task");
                     ("stage", `String "inspect");
                     ( "artifact_scope",
                       `List
                         (List.map (fun value -> `String value) resolved_scope) );
                     ("search_strategy", `String "best_first_v1");
                     ("note", `String "repo_synthesis_wrapper");
                   ])
             with
            | Error message -> `Assoc [ ("error", `String message) ]
            | Ok operation_record -> (
                match ctx.start_team_session with
                | None ->
                    `Assoc
                      [
                        ( "error",
                          `String
                            "masc_repo_synthesis_swarm_start requires team-session launch support" );
                      ]
                | Some start_team_session ->
                    let operation_id = Some operation_record.operation_id in
                    let trace_id = Some operation_record.trace_id in
                    let session_goal =
                      Printf.sprintf
                        "Repo synthesis goal: %s\nQuestion: %s\nRepo root: %s"
                        goal resolved_question repo_root
                    in
                    (match
                       start_team_session ~goal:session_goal ~operation_id
                         ~loop_id:"repo-synthesis" ~target_file:"repo-synthesis"
                         ~program_note
                     with
                    | Error message -> `Assoc [ ("error", `String message) ]
                    | Ok session_json -> (
                        match parse_session_launch ctx session_json with
                        | Error message ->
                            `Assoc [ ("error", `String message) ]
                        | Ok (session_id, artifacts_dir) -> (
                            let planned_worker_roles =
                              repo_synthesis_planned_worker_roles ~max_workers
                            in
                                let run_id =
                                  Repo_synthesis_benchmark.make_run_id ()
                                in
                                let report_json_path =
                                  Filename.concat artifacts_dir "report.json"
                                in
                                let report_md_path =
                                  Filename.concat artifacts_dir "report.md"
                                in
                                let proof_json_path =
                                  Filename.concat artifacts_dir "proof.json"
                                in
                                let proof_md_path =
                                  Filename.concat artifacts_dir "proof.md"
                                in
                                let recommended_next_tools =
                                  [
                                    "masc_operator_snapshot";
                                    "masc_operator_digest";
                                    "masc_team_session_step";
                                    "masc_team_session_prove";
                                    "masc_operation_checkpoint";
                                  ]
                                in
                                let run : Repo_synthesis_benchmark.run_record =
                                  {
                                    benchmark_run_id = run_id;
                                    created_at = Types.now_iso ();
                                    created_by = Some agent_name;
                                    goal;
                                    question = resolved_question;
                                    question_id = resolved_question_id;
                                    repo_root;
                                    artifact_scope = resolved_scope;
                                    program_note;
                                    baseline_label;
                                    model;
                                    max_workers;
                                    time_budget_sec;
                                    workload_profile = "coding_task";
                                    operation_id;
                                    trace_id;
                                    session_id = Some session_id;
                                    report_json_path = Some report_json_path;
                                    report_md_path = Some report_md_path;
                                    proof_json_path = Some proof_json_path;
                                    proof_md_path = Some proof_md_path;
                                    dataset_ref;
                                    case_refs =
                                      (match resolved_question_id with
                                      | Some value -> [ value ]
                                      | None -> []);
                                    planned_worker_roles;
                                    recommended_next_tools;
                                    status = "started";
                                  }
                                in
                                Repo_synthesis_benchmark.save_run
                                  ~base_path:ctx.base_path run;
                                append_repo_synthesis_seed_event config
                                  session_id
                                  (`Assoc
                                    [
                                      ("benchmark_run_id", `String run_id);
                                      ("goal", `String goal);
                                      ("question", `String resolved_question);
                                      ( "question_id",
                                        match resolved_question_id with
                                        | Some value -> `String value
                                        | None -> `Null );
                                      ( "artifact_scope",
                                        `List
                                          (List.map
                                             (fun value -> `String value)
                                             resolved_scope) );
                                      ("repo_root", `String repo_root);
                                      ("ts_iso", `String (Types.now_iso ()));
                                    ]);
                                let dispatch_tick_summary =
                                  match operation_id with
                                  | Some op_id -> (
                                      match
                                        Command_plane_v2.dispatch_tick_json
                                          config ~actor:agent_name
                                          (`Assoc
                                            [ ("operation_id", `String op_id) ])
                                      with
                                      | Ok json -> json
                                      | Error message ->
                                          `Assoc [ ("warning", `String message) ])
                                  | None -> `Null
                                in
                                `Assoc
                                  [
                                    ("benchmark_run_id", `String run_id);
                                    ( "operation_id",
                                      Option.fold ~none:`Null
                                        ~some:(fun value -> `String value)
                                        operation_id );
                                    ( "trace_id",
                                      Option.fold ~none:`Null
                                        ~some:(fun value -> `String value)
                                        trace_id );
                                    ("session_id", `String session_id);
                                    ("artifacts_dir", `String artifacts_dir);
                                    ("report_json_path", `String report_json_path);
                                    ("report_md_path", `String report_md_path);
                                    ("proof_json_path", `String proof_json_path);
                                    ("proof_md_path", `String proof_md_path);
                                    ("workload_profile", `String "coding_task");
                                    ( "planned_worker_roles",
                                      `List
                                        (List.map
                                           (fun value -> `String value)
                                           planned_worker_roles) );
                                    ( "recommended_next_tools",
                                      `List
                                        (List.map
                                           (fun value -> `String value)
                                           recommended_next_tools) );
                                    ("dispatch_tick", dispatch_tick_summary);
                                    ("status", `String "started");
                                  ])))))
