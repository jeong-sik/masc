open Masc
module S=Store_scope_test
module O=Owner_scope_test
module B=Owner_before
let get = function Ok x->x | Error _->failwith "fixture setup failed"
let owned x=get (Result.map_error O.error_to_string x)
let before x=get (Result.map_error B.error_to_string x)
let checks=ref 0
let check label value=incr checks;if not value then failwith label
let collect ()=Gc.full_major ();Gc.full_major ()
let weak value=let w=Weak.create 1 in Weak.set w 0 (Some value);w
let counts ()=Atomic.get Metrics.hashes,Atomic.get Metrics.parses,Atomic.get Metrics.reads
let expect label expected=check label (counts ()=expected)
let counter=ref 0
let scope="scope-native-fixture"
let id="original-one"
let root=Sys.getenv "MASC_BASE_PATH"
let canonical x=get (Lane_addon_action.canonical x)
let row store=Option.get (owned (O.load ~store ~scope ~request_id:id))
let retain store request_id bytes =
  let request=`Assoc ["payload",`String (String.make bytes 'x');"request",`String request_id] in
  owned (O.retain ~store ~scope ~request_id
    ~installation_id:(O.installation_id (O.Configuration "fixture")) ~package_id:"fixture"
    ~tool:"read" ~summary:`Null ~request)
let[@inline never] fixture bytes =
  incr counter;let path=Filename.concat root ("store-" ^ string_of_int !counter) in
  Unix.mkdir path 0o700;let store=S.create ~root:path in retain store id bytes;store
let body_path store record=Filename.concat (S.root store)
  (S.tool_request_body_path ~scope ~request_digest:record.O.request_digest)
let write path bytes=Out_channel.with_open_bin path (fun c->output_string c bytes)
let replace name value = function
 | `Assoc fields->`Assoc (List.map (fun (key,old)->key,(if key=name then value else old)) fields)
 | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _->failwith "fixture metadata"
let metadata store transform =
  let record=row store in
  get (S.save_tool_request_owner store ~scope ~request_id:id (canonical (transform (O.to_json record))))
let baseline_records store=before (B.load_scope ~store ~scope)
let[@inline never] baseline_first store=ignore (baseline_records store)
let[@inline never] same_case bytes =
  let store=fixture bytes in Metrics.reset ();collect ();
  let allocation=Gc.allocated_bytes () in baseline_first store;let baseline=baseline_records store in
  let baseline_alloc=Gc.allocated_bytes ()-.allocation in expect "baseline hashes2 parses2 atomicreads2" (2,2,2);
  Metrics.reset ();collect ();let allocation=Gc.allocated_bytes () in
  let first,observation=owned (O.observe_scope ~store ~scope) in
  let second=owned (O.reread_scope observation) in
  let candidate_alloc=Gc.allocated_bytes ()-.allocation in expect "reuse hashes2 parses1 atomicreads2" (2,1,2);
  check "request AST reused" ((List.hd first).O.request==(List.hd second).O.request);
  check "complete result unchanged" (List.map B.to_json baseline=List.map O.to_json second);
  Metrics.reset ();ignore (owned (O.reread_scope observation));expect "spent hint does full read" (1,1,1);
  `Assoc ["input_bytes",`Int bytes;"baseline_allocated_bytes",`Float baseline_alloc;
    "candidate_allocated_bytes",`Float candidate_alloc;
    "spent_hint_reachable_bytes",`Int (Obj.reachable_words (Obj.repr observation)*8)]
let observe store=owned (O.observe_scope ~store ~scope)
let observation store=snd (observe store)
let remove store record=get (Result.map_error O.settle_error_to_string
  (O.settle ~store ~date:"2026-11-17" (O.listed record)))
let[@inline never] phase_observation store =
  let records,hint=observe store in
  let record=List.hd records in
  hint,weak record.O.request,weak record.progress,!Metrics.raw
let[@inline never] baseline_phase store =
  let records=baseline_records store in weak (List.hd records).B.request
let phase_case bytes =
  let store=fixture bytes in
  let baseline_weak=baseline_phase store in collect ();
  check "baseline first AST can retire before later part proof" (not (Weak.check baseline_weak 0));
  let old=row store in
  ignore (get (O.advance_events ~store ~expected:old ~events:[Lane_addon_request_progress.Dispatch_intended;
    Execution_observed (Waiting (`Assoc ["evidence",`String (String.make 65536 'p')]))]));
  Metrics.reset ();let hint,ast,progress,raw=phase_observation store in collect ();
  check "hint holds AST between discovery and later forest proof" (Weak.check ast 0);
  check "hint does not hold prior owner progress" (not (Weak.check progress 0));
  check "hint does not retain raw read bytes" (List.for_all (fun w->not (Weak.check w 0)) raw);
  let part_work=Array.init 16 (fun i->String.make 65536 (Char.chr (97+i))) in
  collect ();let work=Obj.reachable_words (Obj.repr part_work)*8 in
  let union=Obj.reachable_words (Obj.repr (part_work,hint))*8 in
  let hint_bytes=Obj.reachable_words (Obj.repr hint)*8 in
  ignore (owned (O.reread_scope hint));collect ();
  check "consumed hints release old AST after result discarded" (not (Weak.check ast 0));
  `Assoc ["input_bytes",`Int bytes;"synthetic_part_work_bytes",`Int work;
    "work_plus_hint_union_bytes",`Int union;"hint_bytes_during_later_proof",`Int hint_bytes;
    "extra_phase_root_bytes",`Int (union-work)]
let expect_error label expected result=check label (Result.map_error O.error_to_string result=Error expected)
let unavailable detail=O.error_to_string (O.Store_unavailable detail)
let cases () =
  let store=fixture 4096 in let hint=observation store in
  let current=row store in
  ignore (get (O.advance ~store ~expected:current ~event:Lane_addon_request_progress.Dispatch_intended));
  Metrics.reset ();let records=owned (O.reread_scope hint) in expect "progress still hash1 parse0 read1" (1,0,1);
  check "fresh advanced progress returned" (Lane_addon_request_progress.events (List.hd records).O.progress=[Dispatch_intended]);
  let store=fixture 4096 in let hint=observation store in metadata store (replace "tool" (`String "changed"));
  Metrics.reset ();let records=owned (O.reread_scope hint) in expect "changed binding fullparse hashonce" (1,1,1);
  check "changed fresh binding returned" ((List.hd records).O.tool="changed");
  let store=fixture 4096 in let hint=observation store in
  let request=canonical (`Assoc ["replacement",`String "new body"]) in
  let digest=get (O.request_digest request) in
  get (S.save_tool_request_body store ~scope ~request_digest:digest (Yojson.Safe.to_string request));
  metadata store (replace "request_digest" (`String digest));Metrics.reset ();
  let records=owned (O.reread_scope hint) in expect "changed body hashesonce parsesonce" (1,1,1);
  check "changed body returned" ((List.hd records).O.request=request);
  let store=fixture 4096 in let hint=observation store in retain store "new-original" 1024;
  Metrics.reset ();let records=owned (O.reread_scope hint) in expect "new row parseonce bothhashonce" (2,1,2);
  check "new row included" (List.length records=2);
  let store=fixture 4096 in let current=row store in let hint=observation store in
  Unix.unlink (body_path store current);Metrics.reset ();
  expect_error "missing body refuses" (unavailable "original request body named by its record is missing") (O.reread_scope hint);
  expect "missing hashes0 parses0 atomicread1" (0,0,1);
  get (S.save_tool_request_body store ~scope ~request_digest:current.O.request_digest
    (Yojson.Safe.to_string current.request));Metrics.reset ();
  ignore (owned (O.reread_scope hint));expect "failed hint laterread fullvalidates" (1,1,1);
  let store=fixture 4096 in let current=row store in let hint=observation store in
  write (body_path store current) "corrupt";Metrics.reset ();
  expect_error "corrupt hit refuses beforeparse" (unavailable "original request body does not match its record's digest") (O.reread_scope hint);
  expect "corrupt hashonce parse0" (1,0,1);
  let store=fixture 4096 in let current=row store in let hint=observation store in
  let path=body_path store current in Unix.unlink path;Unix.symlink "not-a-body" path;Metrics.reset ();
  let result=O.reread_scope hint in expect "unreadable body is not hashed" (0,0,1);
  let old=B.load_scope ~store ~scope in
  check "unreadable body keeps baseline exact error" (Result.map_error O.error_to_string
    (Result.map (List.map O.to_json) result)=Result.map_error B.error_to_string (Result.map (List.map B.to_json) old));
  let store=fixture 4096 in let current=row store in let hint=observation store in remove store current;
  Metrics.reset ();check "removed fresh inventory not replayed" (owned (O.reread_scope hint)=[]);expect "removed no body read" (0,0,0);
  let store=fixture 4096 in let current=row store in let hint=observation store in Metrics.reset ();
  expect_error "listed then disappeared refuses" (unavailable "an inventoried original disappeared")
    (O.For_testing.reread_scope ~after_inventory:(fun ()->remove store current) hint);
  expect "listed removed has atomicread no hash" (0,0,1);
  let store=fixture 4096 in let current=row store in let hint=observation store in
  let changed=canonical (replace "tool" (`String "changed") (O.to_json current)) in Metrics.reset ();
  expect_error "listed changed check remains afterbody" (unavailable "an inventoried original changed")
    (O.For_testing.reread_scope ~after_inventory:(fun ()->
       get (S.save_tool_request_owner store ~scope ~request_id:id changed)) hint);
  expect "changed metadata misses proof hashesonce parsesonce" (1,1,1);
  let store=fixture 4096 in let current=row store in let hint=observation store in
  let changed=canonical (replace "tool" (`String "changed") (O.to_json current)) in Metrics.reset ();
  expect_error "body error precedes listed identity error" (unavailable "original request body does not match its record's digest")
    (O.For_testing.reread_scope ~after_inventory:(fun ()->
       get (S.save_tool_request_owner store ~scope ~request_id:id changed);write (body_path store current) "corrupt") hint);
  expect "corrupt mismatch hashonce parse0" (1,0,1)
let[@inline never] cancellation store =
  let hint,ast,_,_=phase_observation store in Metrics.reset ();
  let cancelled=try ignore (O.For_testing.reread_scope
      ~after_inventory:(fun ()->raise (Eio.Cancel.Cancelled Exit)) hint);false with
    | Eio.Cancel.Cancelled Exit->true in
  check "cancellation propagates" cancelled;expect "cancel before body" (0,0,0);hint,ast
let cancel_case () =
  let store=fixture 4096 in let hint,ast=cancellation store in collect ();
  check "cancel consumed hint releases AST" (not (Weak.check ast 0));
  Metrics.reset ();ignore (owned (O.reread_scope hint));expect "cancelled hint subsequent read fullvalidates" (1,1,1)
let concurrent () =
  let store=fixture 4096 in let originals,hint=observe store in Metrics.reset ();
  let a=ref None and b=ref None in
  let start slot=Thread.create (fun ()->slot:=Some (O.reread_scope hint)) () in
  let ta=start a and tb=start b in Thread.join ta;Thread.join tb;
  let a=owned (Option.get !a) and b=owned (Option.get !b) in
  expect "two concurrent reads one hint twohashes oneparse" (2,1,2);
  check "concurrent output same" (List.map O.to_json a=List.map O.to_json b);
  let ast=(List.hd originals).O.request in
  check "exactly one concurrent caller reuses AST" (((List.hd a).O.request==ast)<>((List.hd b).O.request==ast))
let[@inline never] many_observation store =
  let rows,hint=observe store in hint,List.map (fun r->weak r.O.request) rows
let[@inline never] mutate_all store retired =
  let rows=owned (O.load_scope ~store ~scope) in
  List.iter (fun r ->
    if retired then remove store r else
    get (S.save_tool_request_owner store ~scope ~request_id:r.O.request_id
      (canonical (replace "tool" (`String "changed") (O.to_json r))))) rows;
  if retired then List.iteri (fun i _->retain store ("replacement-" ^ string_of_int i) 65536) rows
let overlap_case retired =
  let store=fixture 65536 in for i=1 to 3 do retain store ("another-"^string_of_int i) 65536 done;
  let hint,old=many_observation store in mutate_all store retired;Metrics.reset ();
  let samples=ref [] in
  Metrics.sample:=(fun ()->
    collect ();
    let old=List.filter_map (fun w->Weak.get w 0) old in
    let fresh=List.filter_map (fun w->Weak.get w 0) !Metrics.requests in
    samples:=`Assoc ["old_ast_count",`Int (List.length old);"fresh_ast_count",`Int (List.length fresh);
      "ast_union_bytes",`Int (Obj.reachable_words (Obj.repr (old,fresh))*8)]:: !samples);
  let rows=owned (O.reread_scope hint) in Metrics.sample:=(fun ()->());
  expect "changed or replaced inventory hashesonce parsesonce each" (4,4,4);
  check "all fresh originals returned" (List.length rows=4);
  collect ();check "old changed ASTs released after read" (List.for_all (fun w->not (Weak.check w 0)) old);
  check "unused old ASTs released before first body read" (List.for_all (fun sample->
    Yojson.Safe.Util.(sample |> member "old_ast_count" |> to_int)=0) !samples);
  `Assoc ["kind",`String (if retired then "retired-and-new" else "all-bindings-changed");
    "read_boundary_samples",`List (List.rev !samples)]
let malformed_cases () =
  List.iter (fun bytes ->
    let store=fixture 4096 in let hint=observation store in
    let digest=S.digest bytes in
    get (S.save_tool_request_body store ~scope ~request_digest:digest bytes);
    metadata store (replace "request_digest" (`String digest));Metrics.reset ();
    let result=O.reread_scope hint in
    expect "changed malformed body hashes and parses once" (1,1,1);
    let original=B.load_scope ~store ~scope in
    check "malformed body error byte-equals ordinary load" (match result,original with
      | Error candidate,Error baseline -> O.error_to_string candidate=B.error_to_string baseline
      | (Ok _ | Error _),(Ok _ | Error _)->false))
    ["{";" { \"b\": 2, \"a\": 1 } ";"{\"a\":1,\"a\":2}"]
let cpu_rounds () =
  let store=fixture 262144 in
  let baseline ()=baseline_first store;ignore (baseline_records store) in
  let candidate ()=let hint=observation store in ignore (owned (O.reread_scope hint)) in
  baseline ();candidate ();
  let trial candidate_first =
    let one name run expected =
      Metrics.reset ();collect ();let start=Unix.times () in
      for _=1 to 12 do run () done;
      let stop=Unix.times () in expect "timed native pair counts" expected;
      `Assoc ["kind",`String name;"pairs",`Int 12;
        "process_cpu_seconds",`Float ((stop.Unix.tms_utime+.stop.tms_stime)-.(start.tms_utime+.start.tms_stime))] in
    if candidate_first then
      let first=one "candidate" candidate (24,12,24) in
      let second=one "baseline" baseline (24,24,24) in [first;second]
    else
      let first=one "baseline" baseline (24,24,24) in
      let second=one "candidate" candidate (24,12,24) in [first;second] in
  List.init 6 (fun i->`Assoc ["round",`Int i;"trials",`List (trial (i mod 2=1))])
let () =
  check "owned temporary root" (Sys.file_exists (Filename.concat root "owned-marker"));
  check "HOME guard active" (Sys.getenv_opt "MASC_TEST_ALLOW_HOME_BASE_PATH"=None);
  let metrics=List.map same_case [16;4096;262144] in
  let phases=List.map phase_case [4096;262144] in
  cases ();malformed_cases ();cancel_case ();concurrent ();
  let overlaps=List.map overlap_case [false;true] in
  let cpu=cpu_rounds () in
  print_endline (Yojson.Safe.to_string (`Assoc ["assertions",`Int !checks;"metrics",`List metrics;
    "phase_retention",`List phases;"cpu_rounds",`List cpu;"changed_overlap",`List overlaps;
    "real_store_io",`Bool true;"counter_only_instrumentation",`Bool true]))
