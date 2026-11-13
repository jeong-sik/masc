open Alcotest

(* Memory search when the admission lookup provenance cannot be read: direct
   current facts stay searchable and the unverifiable alias is withheld. *)
module Memory = Masc.Keeper_memory_os_types
module Current = Masc.Keeper_memory_os_current
module Queue = Masc.Keeper_memory_admission_queue

let require = function Ok value -> value | Error detail -> fail detail
let member = Yojson.Safe.Util.member
let json_string name json = member name json |> Yojson.Safe.Util.to_string

let with_workspace f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  let base_path = Filename.temp_dir "synthetic-admission-export-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key
    (Some (Filename.concat base_path "config")) @@ fun () ->
  Config_dir_resolver.reset ();
  Fun.protect ~finally:Config_dir_resolver.reset (fun () -> f ~base_path)

type lookup_failure_fixture = Journal_gap | Malformed_receipts | Unreadable_receipts

let test_incomplete_lookup_keeps_direct_search_with failure () =
  with_workspace @@ fun ~base_path ->
  let keeper_id = "lookup-gap" and trace_id = "lookup-gap-test" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let fact claim : Memory.fact =
    { claim; category=Memory.Constraint; first_seen=100.; last_seen=100.;
      origin={kind=Memory.Authored; trace_id}; basis=Memory.Observed Memory.Transcript } in
  let target = fact "Current consolidated policy" in
  let evidence = fact "UNIQUE-HISTORICAL-ALIAS" in
  ignore (Queue.append ~keepers_dir ~keeper_id ~request_id:"lookup-gap-input" evidence
    |> Result.map_error Queue.append_error_to_string |> require : Queue.candidate);
  let batch = match Queue.read_pending ~keepers_dir ~keeper_id |> require with
    | Some batch -> batch | None -> fail "missing candidate" in
  let candidate_id = match Queue.candidate_ids batch with
    | [id] -> id | _ -> fail "expected one candidate" in
  let binding : Current.admission_recall_binding =
    {candidate_id; source_fact=evidence; target_memory_id=Memory.memory_id target} in
  let born = Current.apply_disposition ~pass:Masc.Keeper_memory_commit_pass.Admission ~explicit_candidate_ids:[candidate_id]
    ~admission_recall:{decided_at_revision=None; bindings=[binding]} ~absorbed:[] ~revisions:[]
    ~keepers_dir ~keeper_id ~now:200. ~source:{Current.kind=Current.Librarian;trace_id}
    ~new_claims:[target] () |> require in
  ignore (Current.replace ~keepers_dir ~keeper_id ~expected_revision:(Some born.snapshot.revision) ~now:300.
    ~source:{Current.kind=Current.Explicit_write;trace_id}
    ~facts:[target;fact "UNRELATED-CURRENT-FACT"] () |> require : Current.t);
  (match failure with
   | Journal_gap ->
       let journal = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
       Fs_compat.invalidate_cached_writer journal;
       Fs_compat.save_file journal ""
   | Malformed_receipts | Unreadable_receipts ->
       let path = Current.durable_range_receipt_path ~keepers_dir ~keeper_id in
       Sys.remove path;
       (match failure with
        | Malformed_receipts -> Fs_compat.save_file path "not-json"
        | Unreadable_receipts -> Fs_compat.mkdir_p path
        | Journal_gap -> fail "unexpected journal fixture"));
  let snapshot, coverage =
    Current.read_with_admission_recall_status_for_keepers_dir ~keepers_dir ~keeper_id |> require in
  check bool "healthy snapshot survives unavailable alias proof" true (Option.is_some snapshot);
  check bool "missing provenance remains an explicit error" true (Result.is_error coverage);
  check bool "strict recall still refuses uncertain aliases" true
    (Result.is_error (Current.read_with_admission_recall_for_keepers_dir ~keepers_dir ~keeper_id));
  let config = Masc.Workspace.default_config base_path in
  let meta = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name",`String keeper_id;"trace_id",`String trace_id]) |> require in
  List.iter (fun source ->
    let search query =
      Masc.Keeper_tool_memory_runtime.keeper_memory_search_json ~config ~meta
        ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
        ~args:(`Assoc ["source",`String source;"query",`String query])
      |> Yojson.Safe.from_string in
    let direct = search "UNRELATED-CURRENT-FACT" in
    check int "unrelated current fact remains searchable" 1
      (member "match_count" direct |> Yojson.Safe.Util.to_int);
    let alias = search "UNIQUE-HISTORICAL-ALIAS" in
    check int "unverifiable historical alias is withheld" 0
      (member "match_count" alias |> Yojson.Safe.Util.to_int);
    check bool "incomplete lookup never asserts absence" true (member "no_match" alias = `Null);
    check string "query-matching historical lookup gap is model-visible" "incomplete"
      (member "successor_recall" alias |> json_string "status"))
    ["current";"all"]

let () =
  run "synthetic admission exact store replay"
    ["lookup coverage",[test_case "incomplete provenance preserves direct search" `Quick
       (test_incomplete_lookup_keeps_direct_search_with Journal_gap);
       test_case "malformed receipts preserve direct search" `Quick
         (test_incomplete_lookup_keeps_direct_search_with Malformed_receipts);
       test_case "unreadable receipts preserve direct search" `Quick
         (test_incomplete_lookup_keeps_direct_search_with Unreadable_receipts)]]
