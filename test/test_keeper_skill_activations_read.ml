(* RFC-0483: one Keeper's skill activation ledger is read on its own. The
   activations answer carries the projection; the usage answer carries only
   the per-surface counts and says which of its closed states the Keeper is
   in. *)

open Alcotest

module Ledger = Masc.Keeper_skill_activation_ledger
module Read = Server_keeper_skill_activations_read

let with_workspace f =
  let base_path = Masc_test_deps.setup_test_workspace () in
  let previous_fs = Fs_compat.get_fs_opt () in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect ~finally:(fun () ->
    Server_auth.For_testing.restore_server_state previous_state;
    (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
    Masc_test_deps.cleanup_test_workspace base_path)
    (fun () -> Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run (fun sw ->
        Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
          ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
          (fun () ->
            let state = Masc.Mcp_server.For_testing.create_state ~base_path in
            Server_auth.For_testing.restore_server_state (Some state);
            let config = Masc.Mcp_server.workspace_config state in
            ignore (Workspace_core.init config ~agent_name:(Some "test"));
            f config))))

let member key json = Yojson.Safe.Util.member key json
let text key json = Yojson.Safe.Util.to_string (member key json)

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700
  end

let write_file path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content)

(* A Keeper with a current session: its metadata names a trace and the trace
   has a session directory for the ledger. *)
let persist_session config keeper_name =
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String keeper_name; "trace_id", `String ("trace-" ^ keeper_name) ])
    with
    | Ok meta -> meta
    | Error detail -> fail detail
  in
  (match Masc.Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> fail detail);
  mkdir_p
    (Masc.Keeper_fs.keeper_session_dir config
       (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
  meta

let revision parse value =
  match parse value with
  | Ok revision -> revision
  | Error _ -> fail "invalid revision fixture"

let record_one config (meta : Masc.Keeper_meta_contract.keeper_meta) ~call
    (reference : Skill_reference.t) =
  let activation =
    match
      Ledger.make_activation
        ~identity:reference.identity
        ~content_revision:reference.content_revision
        ~snapshot_revision:
          (revision Skill_catalog_snapshot.snapshot_revision_of_string (String.make 64 'b'))
        ~turn_ref:
          (Ids.Turn_ref.make
             ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
             ~absolute_turn:1)
        ~runtime_id:"test.runtime"
        ~skill_tool_use_id:call
        ~agent_core_turn:0
        ~invocation:
          (Ledger.Instruction_invocation
             { origin = Ledger.Session_instruction
             ; served_content = Ledger.Skill_body { bytes = 4; sha256 = String.make 64 'c' }
             })
        ~activated_at:"2026-11-04T00:00:00Z"
    with
    | Ok activation -> activation
    | Error _ -> fail "activation fixture rejected"
  in
  match Ledger.record ~config ~trace_id:meta.runtime.trace_id activation with
  | Ok _ -> ()
  | Error error -> fail (Ledger.store_error_to_string error)

let reference_of_unused_skill =
  Skill_reference.make
    ~identity:
      (Skill_reference.make_identity
         ~source_id:
           (match Skill_source_config.source_id_of_string "workspace" with
            | Ok source_id -> source_id
            | Error detail -> fail detail)
         ~package_id:
           (match Skill_reference.package_id_of_directory "unlisted" with
            | Ok package_id -> package_id
            | Error _ -> fail "invalid package fixture")
         ~name:"unlisted")
    ~content_revision:
      (revision Skill_reference.content_revision_of_string (String.make 64 'a'))

(* One workspace skill, published as the ready catalog. Answers its exact
   reference. *)
let publish_catalog (config : Masc.Workspace.config) =
  let base_path = config.base_path in
  let package = Filename.concat (Filename.concat base_path "skills") "sample" in
  mkdir_p package;
  write_file (Filename.concat package "SKILL.md")
    "---\nname: sample\ndescription: A fixture skill.\n---\n\n# Sample\n";
  let path = Filename.concat base_path "runtime-skills.toml" in
  let text =
    "[skills]\nresource-read-max-bytes = 16384\n\n[[skills.sources]]\nid = \"workspace\"\n\
     anchor = \"base-path\"\npath = \"skills\"\naccess = \"read-only\"\n"
  in
  write_file path text;
  (match
     Server_skill_snapshot_runtime.refresh_from_observation ~base_path
       (Runtime.config_observation ~path text)
   with
   | Ok _publication -> ()
   | Error error -> fail (Server_skill_snapshot_runtime.error_to_string error));
  match Server_skill_snapshot_runtime.lookup ~base_path with
  | Ok (Server_skill_snapshot_runtime.Ready { snapshot; config_path = _ }) ->
    let catalog, _diagnostics = Masc.Keeper_skill_catalog.all_entries_of_snapshot snapshot in
    (match
       List.filter_map
         (fun (skill : Masc.Keeper_skill_catalog.skill) -> skill.reference)
         (Masc.Keeper_skill_catalog.skills catalog)
     with
     | [ reference ] -> reference
     | references ->
       fail (Printf.sprintf "expected one published skill, got %d" (List.length references)))
  | Ok (Server_skill_snapshot_runtime.Not_registered | Server_skill_snapshot_runtime.Uninitialized)
  | Error _ -> fail "the published catalog is not ready"

let test_the_activations_answer_carries_only_the_projection () =
  with_workspace @@ fun config ->
  let json = Read.activations_json ~config ~keeper_name:"ghost" in
  check string "the schema" "masc.keeper-skill-activations/v1" (text "schema" json);
  check string "the Keeper it answers for" "ghost" (text "keeper" json);
  check bool "the activation projection is carried" true
    (member "skill_activations" json <> `Null);
  check bool "usage is its own answer" true (member "usage" json = `Null)

let test_a_keeper_without_a_session_answers_no_session () =
  with_workspace @@ fun config ->
  let json = Read.usage_json ~config ~keeper_name:"ghost" in
  check string "the schema" "masc.keeper-skill-usage/v1" (text "schema" json);
  check string "the Keeper it answers for" "ghost" (text "keeper" json);
  check string "no session" "no_session" (text "state" (member "usage" json));
  check bool "the ledger is not carried" true (member "skill_activations" json = `Null)

let test_an_unreadable_ledger_answers_unavailable_with_its_reason () =
  with_workspace @@ fun config ->
  let meta = persist_session config "corrupt" in
  write_file
    (Filename.concat
       (Masc.Keeper_fs.keeper_session_dir config
          (Keeper_id.Trace_id.to_string meta.runtime.trace_id))
       "skill-activation-events.jsonl")
    "not-json";
  let usage = member "usage" (Read.usage_json ~config ~keeper_name:"corrupt") in
  check string "unavailable" "unavailable" (text "state" usage);
  check string "the reason" "activation_ledger_unreadable" (text "reason" usage);
  check bool "the detail is said" true (String.length (text "detail" usage) > 0)

let test_a_read_ledger_without_a_ready_catalog_answers_no_catalog () =
  with_workspace @@ fun config ->
  let meta = persist_session config "analyst" in
  record_one config meta ~call:"call-unlisted" reference_of_unused_skill;
  check string "no catalog" "no_catalog"
    (text "state" (member "usage" (Read.usage_json ~config ~keeper_name:"analyst")))

let test_a_used_catalog_skill_is_one_row () =
  with_workspace @@ fun config ->
  let reference = publish_catalog config in
  let meta = persist_session config "analyst" in
  record_one config meta ~call:"call-sample" reference;
  record_one config meta ~call:"call-unlisted" reference_of_unused_skill;
  let usage = member "usage" (Read.usage_json ~config ~keeper_name:"analyst") in
  check string "ready" "ready" (text "state" usage);
  match Yojson.Safe.Util.to_list (member "rows" usage) with
  | [ row ] ->
    check bool "the row names the catalog skill" true
      (member "reference" row = Skill_reference.to_yojson reference);
    check int "one invocation" 1 (Yojson.Safe.Util.to_int (member "invocations" row));
    check string "when it was used" "2026-11-04T00:00:00Z" (text "last_used_at" row)
  | rows ->
    fail
      (Printf.sprintf "expected one row for the one catalog skill used, got %d"
         (List.length rows))

let () =
  run "keeper_skill_activations_read"
    [ ( "activations"
      , [ test_case "the activations answer carries only the projection" `Quick
            test_the_activations_answer_carries_only_the_projection
        ] )
    ; ( "usage"
      , [ test_case "a Keeper without a session answers no_session" `Quick
            test_a_keeper_without_a_session_answers_no_session
        ; test_case "an unreadable ledger answers unavailable with its reason" `Quick
            test_an_unreadable_ledger_answers_unavailable_with_its_reason
        ; test_case "a read ledger without a ready catalog answers no_catalog" `Quick
            test_a_read_ledger_without_a_ready_catalog_answers_no_catalog
        ; test_case "a used catalog skill is one row" `Quick
            test_a_used_catalog_skill_is_one_row
        ] )
    ]
