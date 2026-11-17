open Masc
module Before = Ledger_before
module After = Ledger_after
module Briefing = Workspace_memory_briefing

let assertions = ref 0
let check label value = incr assertions; if not value then failwith label
let require = function Ok value -> value | Error detail -> failwith detail
let write path bytes = Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let sha text = Agent_core_sha256.(digest_string text |> to_hex)
let ledger_json count bytes =
  let rows=List.init count (fun index ->
    let id=Printf.sprintf "c%04d" index in
    let text=string_of_int index ^ ":" ^ String.init bytes (fun i -> "a\"\\\n0123456789".[i mod 14]) in
    id,text) in
  `Assoc ["schema",`String "workspace.memory.ledger.v1";
    "claims",`List(List.map(fun(id,text)->`Assoc["claim_id",`String id;"claim",`String text])rows);
    "conflicts",`List[];
    "facts",`List(List.map(fun(id,text)->`Assoc[
      "keeper_id",`String "fixture";"store",`String "ordinary";
      "claim_sha256",`String(sha text);
      "disposition",`Assoc["kind",`String "claim";"claim_id",`String id]])rows)]

let before_gate ~base_path = match Before.observe ~base_path with
  | Before.Unavailable detail -> Error detail
  | Before.Missing | Before.Available _ -> Ok ()
let before_observation = function
  | Before.Missing -> `Missing
  | Before.Unavailable detail -> `Error detail
  | Before.Available value -> `Available(value.ledger_sha256,value.claim_count,
      value.conflict_count,value.classified_count,value.excluded_count,value.briefing,value.building)
let after_observation = function
  | After.Missing -> `Missing
  | After.Unavailable detail -> `Error detail
  | After.Available value -> `Available(value.ledger_sha256,value.claim_count,
      value.conflict_count,value.classified_count,value.excluded_count,value.briefing,value.building)

let compare label ~base_path ~readable =
  let before=before_gate ~base_path and after=After.check_readable ~base_path in
  check(label ^ " availability/error unchanged") (before=after);
  check(label ^ " independent expected availability") (Result.is_ok after=readable);
  check(label ^ " full observation unchanged")
    (before_observation(Before.observe ~base_path)=after_observation(After.observe ~base_path))

let core_cases root =
  let base_path=Filename.concat root "cases" in Unix.mkdir base_path 0o700;
  compare "absent ledger" ~base_path ~readable:true;
  let json=ledger_json 2 4096 in
  let ledger=require(Before.of_json json) in
  require(Before.save ~base_path ledger);
  compare "valid ledger" ~base_path ~readable:true;
  let directory=Before.directory ~base_path in
  let path=Filename.concat directory "ledger.json" in
  write (Briefing.path ~directory) "{broken";
  compare "corrupt briefing is not ledger unavailability" ~base_path ~readable:true;
  write path "{broken";
  compare "corruption after successful read" ~base_path ~readable:false;
  write path "{\"schema\":\"workspace.memory.ledger.v1\",\"claims\":[{\"claim_id\":\"c1\",\"claim\":\"orphan\"}],\"conflicts\":[],\"facts\":[]}";
  compare "parsed but invalid ledger references" ~base_path ~readable:false;
  write path "{\"schema\":\"other\",\"claims\":[],\"conflicts\":[],\"facts\":[]}";
  compare "unknown schema" ~base_path ~readable:false;
  require(Before.save ~base_path ledger);
  compare "valid replacement read afresh" ~base_path ~readable:true;
  let held=path ^ ".held" in Unix.rename path held;Unix.symlink held path;
  compare "symlink to valid bytes" ~base_path ~readable:false;
  Unix.unlink path;Unix.symlink (path ^ ".absent") path;
  compare "dangling symlink" ~base_path ~readable:false;
  Unix.unlink path;Unix.mkdir path 0o700;
  compare "directory" ~base_path ~readable:false;
  Unix.rmdir path;Unix.mkfifo path 0o600;
  compare "fifo rejected without opening it" ~base_path ~readable:false;
  Unix.unlink path;
  compare "removed ledger" ~base_path ~readable:true;
  compare "absent workspace" ~base_path:(Filename.concat root "absent") ~readable:false

let measure repetitions operation =
  Gc.full_major ();
  let allocated_before=Gc.allocated_bytes () and cpu_before=Sys.time ()
  and wall_before=Unix.gettimeofday () in
  for _=1 to repetitions do ignore(Sys.opaque_identity(require(operation ()))) done;
  let wall=Unix.gettimeofday ()-.wall_before and cpu=Sys.time ()-.cpu_before
  and bytes=Gc.allocated_bytes ()-.allocated_before in
  `Assoc["counter_allocated_bytes",`Float bytes;"process_cpu_seconds",`Float cpu;
    "wall_seconds",`Float wall;"repetitions",`Int repetitions]

let performance_case root count bytes =
  let base_path=Filename.concat root (Printf.sprintf "perf-%d-%d" count bytes) in
  Unix.mkdir base_path 0o700;
  let ledger=require(Before.of_json(ledger_json count bytes)) in
  require(Before.save ~base_path ledger);
  let directory=Before.directory ~base_path in
  let template=(Prompt_registry.resolve_prompt Prompt_names.workspace_memory_briefing).effective in
  let contract=Briefing.contract ~template in
  let state=match require(Briefing.prepare ~sources:(Before.briefing_sources ledger) ~contract
    ~render:(fun json -> Ok(Yojson.Safe.to_string json)) Briefing.empty) with
    | Briefing.Prepared batch -> Briefing.prepared_state batch
    | Briefing.Unchanged | Briefing.Cleanup _ -> failwith "fixture prepared no briefing" in
  require(Briefing.save ~directory state);
  compare "valid ledger and retained briefing preparation" ~base_path ~readable:true;
  require(before_gate ~base_path);require(After.check_readable ~base_path);
  let rounds=List.init 4 (fun index ->
    let before,after=if index mod 2=0 then
      let before=measure 8 (fun()->before_gate ~base_path) in
      let after=measure 8 (fun()->After.check_readable ~base_path) in before,after
    else let after=measure 8 (fun()->After.check_readable ~base_path) in
      let before=measure 8 (fun()->before_gate ~base_path) in before,after in
    `Assoc["before",before;"after",after]) in
  `Assoc["claim_count",`Int count;"message_bytes_per_claim",`Int bytes;
    "ledger_file_bytes",`Int((Unix.stat(Filename.concat directory "ledger.json")).st_size);
    "briefing_file_bytes",`Int((Unix.stat(Briefing.path ~directory)).st_size);
    "rounds",`List rounds]

let () =
  let root=Unix.realpath(Sys.getenv "MASC_BASE_PATH") in
  check "owned fixture root" (Sys.file_exists(Filename.concat root "owned-fixture-marker"));
  let prompts=Filename.concat root "prompts" in Unix.mkdir prompts 0o700;
  write(Filename.concat prompts(Prompt_names.workspace_memory_briefing ^ ".md"))
    "---\ndescription: fixture\ncategory: test\n---\nSynthetic workspace briefing";
  Prompt_registry.clear ();Prompt_registry.set_markdown_dir prompts;
  core_cases root;
  let cases=List.map(fun(count,bytes)->performance_case root count bytes)[4,4096;16,16384] in
  print_endline(Yojson.Safe.to_string(`Assoc["assertions",`Int !assertions;"cases",`List cases;
    "scope",`String "actual complete Ledger modules and owned Store files; standalone current-domain counters and process CPU, not HTTP/cache/pool or server performance";
    "live_runtime_actions",`Bool false]))
