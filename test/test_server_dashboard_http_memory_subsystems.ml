open Alcotest

module Json = Yojson.Safe.Util
module Memory_subsystems = Server_dashboard_http_memory_subsystems
module Memory_io = Masc.Keeper_memory_os_io
module P = Masc.Procedural_memory
module Projection = Masc.Skill_candidate_projection
module Store = Masc.Skill_candidate_store
module Delegation_request = Masc.Keeper_delegation_request
module Delegation_store = Masc.Keeper_delegation_request_store
module Types = Masc.Keeper_memory_os_types

let request target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list []) `GET target
;;

let check_include target expected =
  check
    bool
    target
    expected
    (Memory_subsystems.dashboard_memory_subsystems_include_entries (request target))
;;

let temp_dir () =
  Filename.temp_dir "memory_subsystems_dashboard_test" ""
;;

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path)
      else Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let test_include_entries_query_param () =
  check_include "/dashboard/memory-subsystems" false;
  check_include "/dashboard/memory-subsystems?include_memory_entries=1" true;
  check_include "/dashboard/memory-subsystems?include_memory_entries=true" true;
  check_include "/dashboard/memory-subsystems?include_memory_entries=yes" true;
  check_include "/dashboard/memory-subsystems?include_memory_entries=y" true;
  check_include "/dashboard/memory-subsystems?include_memory_entries=0" false;
  check_include "/dashboard/memory-subsystems?include_memory_entries=false" false;
  check_include "/dashboard/memory-subsystems?include_memory_entries=no" false;
  check_include "/dashboard/memory-subsystems?include_memory_entries=n" false
;;

let test_focus_entries_enables_memory_entries () =
  check_include "/dashboard/memory-subsystems?focus=entries" true;
  check_include "/dashboard/memory-subsystems?focus=%20entries%20" true;
  check_include "/dashboard/memory-subsystems?focus=episodes" false
;;

let test_http_json_explicitly_disabled_entries_surface () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let json =
        Memory_subsystems.dashboard_memory_subsystems_http_json
          ~config
          ~include_memory_entries:false
          (request "/dashboard/memory-subsystems?limit=9999&focus=entries")
      in
      let memory_entries = Json.(json |> member "memory_entries") in
      check int "memory total" 0 Json.(memory_entries |> member "total" |> to_int);
      check
        int
        "memory filtered"
        0
        Json.(memory_entries |> member "filtered" |> to_int);
      check int "memory shown" 0 Json.(memory_entries |> member "shown" |> to_int);
      check int "limit clamped" 500 Json.(memory_entries |> member "limit" |> to_int);
      check
        int
        "items empty"
        0
        Json.(memory_entries |> member "items" |> to_list |> List.length))
;;

let fact ?(category = Types.Preference) ?(trace_id = "trace-user-model")
      ?(turn = 3) ?(first_seen = 10.0) ?last_verified_at claim
  : Types.fact
  =
  { claim
  ; category
  ; external_ref = None
  ; source = { trace_id; turn; tool_call_id = None }
  ; observed_by = []
  ; first_seen
  ; valid_until = None
  ; last_verified_at
  ; schema_version = Types.schema_version
  ; claim_id = None
  }
;;

let test_http_json_surfaces_user_model_projection () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let keepers_dir =
        Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
      in
      Memory_io.For_testing.with_keepers_dir keepers_dir (fun () ->
        Memory_io.append_fact
          ~keeper_id:"sangsu"
          (fact ~category:Types.Preference ~last_verified_at:20.0
             "User prefers terse operational summaries");
        Memory_io.append_fact
          ~keeper_id:"sangsu"
          (fact ~category:Types.Constraint ~trace_id:"trace-constraint" ~turn:4
             "User requires worktree-first changes");
        Memory_io.append_fact
          ~keeper_id:"sangsu"
          (fact ~category:Types.Fact "The repo uses OCaml");
        let json =
          Memory_subsystems.dashboard_memory_subsystems_http_json
            ~config
            ~include_memory_entries:false
            (request "/dashboard/memory-subsystems?limit=100")
        in
        let user_model = Json.(json |> member "user_model") in
        check string "schema" "masc.user_model.memory_projection.v1"
          Json.(user_model |> member "schema" |> to_string);
        let prompt = Json.(user_model |> member "prompt") in
        check string "prompt block id" "user_model"
          Json.(prompt |> member "block_id" |> to_string);
        check string "prompt injection" "extra_system_context"
          Json.(prompt |> member "injection" |> to_string);
        check string "prompt hook" "keeper_run_tools_hooks.before_turn_params"
          Json.(prompt |> member "runtime_hook" |> to_string);
        check int "total" 2 Json.(user_model |> member "total" |> to_int);
        check int "shown" 2 Json.(user_model |> member "shown" |> to_int);
        let items = Json.(user_model |> member "items" |> to_list) in
        let claims =
          items |> List.map (fun item -> Json.(item |> member "claim" |> to_string))
        in
        check
          (list string)
          "preference and constraint only"
          [ "User prefers terse operational summaries"
          ; "User requires worktree-first changes"
          ]
          claims))
;;

let test_http_json_user_model_uses_config_base_path () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let base_keepers_dir =
        Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
      in
      Memory_io.For_testing.with_keepers_dir base_keepers_dir (fun () ->
        Memory_io.append_fact
          ~keeper_id:"target"
          (fact ~category:Types.Preference "Target workspace preference"));
      let ambient_keepers_dir = Filename.concat dir "ambient-keepers" in
      Memory_io.For_testing.with_keepers_dir ambient_keepers_dir (fun () ->
        Memory_io.append_fact
          ~keeper_id:"ambient"
          (fact ~category:Types.Preference "Ambient workspace preference");
        let json =
          Memory_subsystems.dashboard_memory_subsystems_http_json
            ~config
            ~include_memory_entries:false
            (request "/dashboard/memory-subsystems?limit=100")
        in
        let user_model = Json.(json |> member "user_model") in
        let items = Json.(user_model |> member "items" |> to_list) in
        let claims =
          items |> List.map (fun item -> Json.(item |> member "claim" |> to_string))
        in
        check (list string) "scoped claims" [ "Target workspace preference" ] claims))
;;

let skill_candidate () =
  let procedure : P.procedure =
    { id = "dashboard-visible-skill"
    ; agent_name = "keeper"
    ; pattern = "When the same repair loop succeeds repeatedly, draft a skill"
    ; evidence = [ "proof-store://abc"; "proof-store://def"; "proof-store://ghi" ]
    ; success_count = 3
    ; failure_count = 0
    ; confidence = 1.0
    ; created_at = 0.0
    ; last_applied = 0.0
    }
  in
  match Projection.candidate_of_procedure procedure with
  | Some candidate -> candidate
  | None -> fail "expected dashboard skill candidate"
;;

let test_http_json_surfaces_draft_skill_candidates () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let candidate = skill_candidate () in
      (match Store.write_candidate ~base_path:dir candidate with
       | Ok _ -> ()
       | Error msg -> fail msg);
      let json =
        Memory_subsystems.dashboard_memory_subsystems_http_json
          ~config
          ~include_memory_entries:false
          (request "/dashboard/memory-subsystems?limit=100")
      in
      let drafts = Json.(json |> member "draft_skill_candidates") in
      check int "draft total" 1 Json.(drafts |> member "total" |> to_int);
      check int "draft shown" 1 Json.(drafts |> member "shown" |> to_int);
      check string "draft index path"
        (Store.index_path ~base_path:dir)
        Json.(drafts |> member "index_path" |> to_string);
      let item =
        match Json.(drafts |> member "items" |> to_list) with
        | [ item ] -> item
        | _ -> fail "expected one draft skill candidate"
      in
      check string "candidate id" candidate.id Json.(item |> member "id" |> to_string);
      check string "candidate state" "candidate"
        Json.(item |> member "promotion_state" |> to_string);
       check string "skill path suffix" "SKILL.md"
         (Filename.basename Json.(item |> member "skill_md_path" |> to_string)))
;;

let test_http_json_surfaces_delegation_requests () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let delegation =
        Delegation_request.make ~requester:"planner"
          ~goal:"ship connector parity"
          ~topic:"Review non-dashboard rendering"
          ~reason:"existing channels lose rich blocks"
          ()
      in
      (match Delegation_store.write_request ~base_path:dir delegation with
       | Ok _ -> ()
       | Error msg -> fail msg);
      let json =
        Memory_subsystems.dashboard_memory_subsystems_http_json
          ~config
          ~include_memory_entries:false
          (request "/dashboard/memory-subsystems?limit=100")
      in
      let requests = Json.(json |> member "delegation_requests") in
      check int "delegation total" 1 Json.(requests |> member "total" |> to_int);
      check int "delegation shown" 1 Json.(requests |> member "shown" |> to_int);
      check string "delegation index path"
        (Delegation_store.index_path ~base_path:dir)
        Json.(requests |> member "index_path" |> to_string);
      let item =
        match Json.(requests |> member "items" |> to_list) with
        | [ item ] -> item
        | _ -> fail "expected one delegation request"
      in
      check string "delegation id" delegation.id
        Json.(item |> member "id" |> to_string);
      check string "delegation requester" "planner"
        Json.(item |> member "requester" |> to_string);
      check string "task seed suffix" "TASK_SEED.md"
        (Filename.basename Json.(item |> member "task_seed_md_path" |> to_string)))
;;

let () =
  Eio_main.run @@ fun _env ->
  Alcotest.run
    "server_dashboard_http_memory_subsystems"
    [ ( "request"
      , [ test_case
            "include_memory_entries accepts explicit bool forms"
            `Quick
            test_include_entries_query_param
        ; test_case
            "focus entries enables memory entries"
            `Quick
            test_focus_entries_enables_memory_entries
        ] )
    ; ( "json"
      , [ test_case
            "explicit disabled entries keeps empty surface"
            `Quick
            test_http_json_explicitly_disabled_entries_surface
        ; test_case
            "surfaces user model projection"
            `Quick
            test_http_json_surfaces_user_model_projection
        ; test_case
            "user model projection reads config base path"
            `Quick
            test_http_json_user_model_uses_config_base_path
        ; test_case
            "surfaces draft skill candidates"
            `Quick
            test_http_json_surfaces_draft_skill_candidates
        ; test_case
            "surfaces delegation requests"
            `Quick
            test_http_json_surfaces_delegation_requests
        ] )
    ]
;;
