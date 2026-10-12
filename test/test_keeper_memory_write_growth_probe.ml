(** Controlled storage-boundary measurement, not a semantic quality benchmark.
    No Librarian, provider or production Keeper is started. The observed counts
    are emitted rather than asserted: this probe must not freeze today's
    immediate-admission behavior as the desired contract. *)
module Current = Masc.Keeper_memory_os_current
module Runtime = Masc.Keeper_tool_memory_runtime
module Queue = Masc.Keeper_memory_admission_queue

let require = function Ok value -> value | Error detail -> Alcotest.fail detail

let run_probe () =
  let base_path = Filename.temp_dir "memory-admission-growth-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let config = Masc.Workspace.default_config base_path in
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    Alcotest.(check bool) "all experiment writes stay in the isolated workspace" true
      (String.starts_with ~prefix:(base_path ^ Filename.dir_sep) keepers_dir);
    let policy = "Production release P-42 requires owner approval before deployment." in
    let cohorts =
      [ "exact_reobservation", (fun _ -> policy), 1
      ; "same_rule_repeated_receipts", (fun n ->
          Printf.sprintf "%s Synthetic check %d reconfirmed this unchanged rule." policy n), 1
      ; "independent_release_rules", (fun n ->
          Printf.sprintf "Production release P-%d requires owner approval before deployment." n), 200
      ] in
    List.iter (fun (cohort,content,declared_knowledge_branches) ->
      let keeper_id = "growth-probe-" ^ cohort in
      let meta = Masc_test_deps.meta_of_json_fixture
        (`Assoc ["name",`String keeper_id;"trace_id",`String ("trace-" ^ cohort)]) |> require in
      let inputs = List.init 200 (fun index ->
        `Assoc ["content",`String (content (index+1))]) in
      let input_sha256 = Digestif.SHA256.(digest_string
        (Yojson.Safe.to_string (`List inputs)) |> to_hex) in
      let receipts = Hashtbl.create 4 in
      List.iteri (fun index args ->
        let result = Runtime.keeper_memory_write_with_outcome ~config ~meta ~args in
        let receipt = Yojson.Safe.from_string result.Masc.Keeper_tool_execution.raw_output in
        if Yojson.Safe.Util.member "ok" receipt <> `Bool true then
          Alcotest.failf "synthetic write failed cohort=%s write=%d: %s"
            cohort (index+1) result.raw_output;
        let outcome = Yojson.Safe.Util.(receipt |> member "outcome" |> to_string) in
        let previous = match Hashtbl.find_opt receipts outcome with None -> 0 | Some n -> n in
        Hashtbl.replace receipts outcome (previous+1);
        let writes = index+1 in
        if List.mem writes [1;29;30;31;100;200] then (
          let snapshot = Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require in
          let facts,revision = match snapshot with
            | None -> [],`Null | Some current -> current.facts,`Int current.revision in
          let fact_bytes = List.map Masc.Keeper_memory_os_types.fact_to_json facts
            |> fun rows -> String.length (Yojson.Safe.to_string (`List rows)) in
          let pending = match Queue.read_pending ~keepers_dir ~keeper_id |> require with
            | None -> [] | Some batch -> Queue.candidates batch in
          let pending_bytes = List.map (fun (row : Queue.candidate) ->
            Masc.Keeper_memory_os_types.fact_to_json row.fact) pending
            |> fun rows -> String.length (Yojson.Safe.to_string (`List rows)) in
          let outcomes = Hashtbl.to_seq receipts |> List.of_seq
            |> List.sort (fun (a,_) (b,_) -> String.compare a b)
            |> List.map (fun (key,n) -> key,`Int n) in
          let sample = `Assoc
            ["schema",`String "masc.memory-write-growth-probe.v2";
             "cohort",`String cohort;"writes",`Int writes;
             "input_sha256",`String input_sha256;
             "declared_final_knowledge_branches",`Int declared_knowledge_branches;
             "current_facts",`Int (List.length facts);"revision",revision;
             "serialized_fact_bytes",`Int fact_bytes;
             "pending_candidates",`Int (List.length pending);
             "serialized_pending_fact_bytes",`Int pending_bytes;
             "write_receipt_outcomes",`Assoc outcomes;
             "effective_limits",Masc.Keeper_memory_limits.(current facts |> to_json);
             "librarian_executed",`Bool false;"provider_calls",`Int 0] in
          Printf.printf "MEMORY_WRITE_GROWTH %s\n%!" (Yojson.Safe.to_string sample))) inputs) cohorts)

let () = Alcotest.run "explicit memory admission growth probe"
  ["isolated storage experiment",[
    Alcotest.test_case "exact repeats, redundant receipts and independent branches through 200 writes"
      `Quick run_probe]]
