open Alcotest
open Masc

(* The repository's .agents/skills reach Keepers through a directory Skill
   source in the operator's runtime.toml. The catalog drops a Skill whose
   body does not fit the inline tool-result boundary, so a body that grows past
   it disappears for every Keeper while nothing fails (#45124). This suite
   publishes the real directory through the server's snapshot publisher and
   projects it the way a Keeper turn does. *)

let skills_anchor = Filename.concat ".agents" "skills"
let source_id = "masc-repo-agents"

(* Dune runs a test from its build directory, which has no dot directories.
   Same shape as test_coding_eval_cases.ml: trust DUNE_SOURCEROOT only when
   the anchor is visible inside it, walk upwards otherwise, and fail loudly
   rather than skipping. *)
let rec find_source_root_from dir depth =
  if depth > 8
  then None
  else if Sys.file_exists (Filename.concat dir skills_anchor)
  then Some dir
  else (
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else find_source_root_from parent (depth + 1))
;;

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root
    when String.trim root <> "" && Sys.file_exists (Filename.concat root skills_anchor)
    -> root
  | _ ->
    (match find_source_root_from (Sys.getcwd ()) 0 with
     | Some root -> root
     | None ->
       fail
         (Printf.sprintf
            "could not locate %s from %s -- the repository Skill contract cannot run"
            skills_anchor
            (Sys.getcwd ())))
;;

let runtime_text =
  Printf.sprintf
    {|[[skills.sources]]
id = "%s"
anchor = "base-path"
path = "%s"
access = "read-only"

[providers.local]
protocol = "ollama-http"
endpoint = "http://127.0.0.1:11434"

[models.sample]
api-name = "sample"
max-context = 1024

[local.sample]

[runtime]
default = "local.sample"
|}
    source_id
    skills_anchor
;;

let repository_skill_directories root =
  let dir = Filename.concat root skills_anchor in
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun name ->
    Sys.file_exists (Filename.concat (Filename.concat dir name) "SKILL.md"))
  |> List.sort String.compare
;;

let from_this_source identity =
  String.equal (Skill_reference.identity_source_id_to_string identity) source_id
;;

let publish root =
  let workspace =
    match Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:root with
    | Ok workspace -> workspace
    | Error error ->
      fail
        (Printf.sprintf
           "repository root %s is not a canonical workspace: %s"
           root
           (Config_dir_resolver.canonical_base_path_error_to_string error))
  in
  let read_config () =
    { Skill_catalog_snapshot_service.path = Filename.concat root "runtime.toml"
    ; source_text = runtime_text
    }
  in
  match Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None ~read_config with
  | Published snapshot | Unchanged snapshot -> snapshot
  | Workspace_retired -> fail "repository workspace was retired during publication"
;;

let rejection_reason_to_string = function
  | Skill_catalog_snapshot.Document_rejected diagnostics ->
    String.concat "; " (List.map Agent_core.Skill_document.diagnostic_to_string diagnostics)
  | Skill_catalog_snapshot.Document_unreadable { path; detail } -> Printf.sprintf "unreadable %s: %s" path detail
  | Skill_catalog_snapshot.Exact_identity_duplicate { first_directory } ->
    "same identity as " ^ first_directory
  | Skill_catalog_snapshot.Invalid_package_id error -> Skill_reference.package_id_error_to_string error
;;

(* Why the snapshot itself left a directory out: a Skill rejected or unread
   before projection is only a missing name in the catalog. *)
let snapshot_context snapshot =
  let rejected =
    Skill_catalog_snapshot.rejections snapshot
    |> List.filter_map (fun (rejection : Skill_catalog_snapshot.rejection) ->
      if String.equal (Skill_source_config.source_id_to_string rejection.source_id) source_id
      then
        Some
          (Printf.sprintf
             "%s: %s"
             rejection.directory
             (rejection_reason_to_string rejection.reason))
      else None)
  in
  Printf.sprintf
    "config %s; snapshot rejections [%s]"
    (Skill_catalog_snapshot.config_state_to_string (Skill_catalog_snapshot.config_state snapshot))
    (String.concat " | " rejected)
;;

let test_every_repository_skill_reaches_keepers () =
  let root = source_root () in
  let expected = repository_skill_directories root in
  check bool "the repository ships Skills" true (expected <> []);
  let snapshot = publish root in
  let catalog, diagnostics = Keeper_skill_catalog.of_snapshot snapshot in
  let projected =
    Keeper_skill_catalog.skills catalog
    |> List.filter_map (fun (skill : Keeper_skill_catalog.skill) ->
      match skill.reference with
      | Some reference when from_this_source reference.Skill_reference.identity ->
        Some (Skill_reference.identity_package_id_to_string reference.identity)
      | Some _ | None -> None)
    |> List.sort String.compare
  in
  (* A diagnostic counts as a refusal only when its Skill is missing from the
     catalog: an advisory or a frozen fallback leaves the Skill offered. *)
  let refused =
    List.filter_map
      (fun (diagnostic : Keeper_skill_catalog.projection_diagnostic) ->
         let package = Skill_reference.identity_package_id_to_string diagnostic.identity in
         if from_this_source diagnostic.identity && not (List.mem package projected)
         then
           Some
             (Printf.sprintf
                "%s: %s"
                package
                (Keeper_skill_catalog.error_to_string diagnostic.error))
         else None)
      diagnostics
  in
  check (list string) "no repository Skill is refused by the catalog" [] refused;
  check
    (list string)
    ("every repository Skill directory is offered; " ^ snapshot_context snapshot)
    expected
    projected
;;

let () =
  run
    "repo_skills_readable"
    [ ( "catalog"
      , [ test_case
            "every repository Skill reaches Keepers"
            `Quick
            test_every_repository_skill_reaches_keepers
        ] )
    ]
;;
