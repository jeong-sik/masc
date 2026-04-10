(** Tool_autoresearch_repo_synthesis — repo-synthesis-specific logic for
    the autoresearch swarm start handler. *)


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

let handle_repo_synthesis_swarm_start _ctx _args =
  (* Team session engine removed — repo synthesis swarm start is no longer supported. *)
  ignore _ctx; ignore _args;
  `Assoc
    [
      ( "error",
        `String
          "masc_repo_synthesis_swarm_start is no longer supported (team session engine removed)" );
    ]

