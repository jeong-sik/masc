open Agent_core
module Before = Objects_before
module After = Objects_after
let get = function Ok value -> value | Error _ -> failwith "fixture construction failed"
let assertions=ref 0
let check label value = incr assertions;if not value then failwith label
let checkpoint messages : Checkpoint.t = {
  provider_binding=None;version=Checkpoint.checkpoint_version;session_id="readonly-fixture";
  agent_name="readonly-fixture";model="synthetic";system_prompt=None;messages;
  usage=Types.empty_usage;turn_count=4;created_at=1.;tools=[];tool_choice=None;
  disable_parallel_tool_use=false;temperature=None;top_p=None;top_k=None;min_p=None;
  reasoning_effort=None;enable_thinking=None;preserve_thinking=None;
  response_format=Types.Off;cache_system_prompt=false;context=Context.create_sync ();
  pending_input=None;mcp_sessions=[];working_context=None}
let[@inline never] fixture ?(turns=4) count size =
  let table=Hashtbl.create 32 and memo=Before.create_memo () in
  let rec build turn messages previous =
    let more=List.init count (fun i ->
      Types.make_message ~role:Types.User [Types.Text (String.make size (Char.chr (97+(turn+i) mod 20)))]) in
    let messages=messages@more in
    let plan=get (Before.plan_save memo ?previous Before.Turn_closes (checkpoint messages)) in
    List.iter (fun ((digest:Before.digest),bytes)->Hashtbl.replace table (digest:>string) bytes) plan.objects;
    if turn=turns then plan.head_bytes,table else build (turn+1) messages (Some plan.head)
  in build 1 [] None
let read table digest = Ok (Hashtbl.find_opt table digest)
let collect () = Gc.full_major ();Gc.full_major ()
let measure table run =
  collect ();let base=(Gc.quick_stat ()).live_words in
  let sampled=ref base in
  let reader digest =
    collect ();sampled:=max !sampled (Gc.quick_stat ()).live_words;
    read table digest in
  let allocation=Gc.allocated_bytes () and cpu=Sys.time () in
  let result=run reader in
  let cpu=Sys.time ()-.cpu and allocated=Gc.allocated_bytes ()-.allocation in
  result,`Assoc ["allocated_bytes",`Float allocated;"cpu_seconds",`Float cpu;
    "sampled_live_growth_bytes",`Int ((!sampled-base)*8)]
let[@inline never] scenario count size =
  let head,table=fixture count size in collect ();
  let before_head=get (Before.head_of_string head) and after_head=get (After.head_of_string head) in
  let memo=Before.create_memo () in
  let (baseline,baseline_stats)=measure table (fun reader ->
    get (Before.load memo ~read_object:(fun d->reader (d:>string)) before_head)) in
  let ((encoded,normal),normal_stats)=measure table (fun reader ->
    let encoded=After.create_memo () in
    encoded,get (After.load encoded ~read_object:(fun d->reader (d:>string)) after_head)) in
  let (readonly,readonly_stats)=measure table (fun reader ->
    get (After.load_read_only ~read_object:(fun d->reader (d:>string)) after_head)) in
  check "old/new ordinary load value" (Codec_before.to_string baseline=Codec_after.to_string normal);
  check "readonly exact checkpoint wire value" (Codec_before.to_string baseline=Codec_after.to_string readonly);
  check "existing memo encoded count preserved" (Before.memo_encoded_bytes memo=After.memo_encoded_bytes encoded);
  let retained=Obj.reachable_words (Obj.repr (normal,encoded)) in
  let readonly_words=Obj.reachable_words (Obj.repr readonly) in
  let resave=get (After.plan_save encoded ~previous:after_head After.Turn_continues normal) in
  check "same memo load then save writes no old objects" (resave.objects=[]);
  `Assoc ["messages",`Int (count*4);"text_bytes_each",`Int size;
    "old",baseline_stats;"new_memo",normal_stats;"read_only",readonly_stats;
    "memo_and_checkpoint_union_bytes",`Int (retained*8);
    "readonly_checkpoint_bytes",`Int (readonly_words*8)]
let error_pair head table =
  let old=Before.load (Before.create_memo ()) ~read_object:(fun d->read table (d:>string))
    (get (Before.head_of_string head)) in
  let new_=After.load_read_only ~read_object:(fun d->read table (d:>string))
    (get (After.head_of_string head)) in
  let a=Result.map Codec_before.to_string (Result.map_error Before.load_error_to_string old) in
  let b=Result.map Codec_after.to_string (Result.map_error After.load_error_to_string new_) in
  check "malformed full load same exact error/result" (a=b)
let set key value = function
 | `Assoc fields -> `Assoc (List.map (fun (name,old)->name,(if name=key then value else old)) fields)
 | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> failwith "fixture object"
let malformed_bundle head table payload extra count =
  let digest=Before.digest_of_bytes payload in
  let bytes=Yojson.Safe.to_string (`Assoc ["messages",`List [`Assoc ["sha256",`String (digest:>string);
    "bytes",`Int (String.length payload)]]]) ^ "\n" ^ payload ^ "\n" ^ extra in
  let bundle=Before.digest_of_bytes bytes in
  let table=Hashtbl.copy table in Hashtbl.replace table (bundle:>string) bytes;
  let json=Yojson.Safe.from_string head in
  let history=Yojson.Safe.Util.member "history" json in
  let turns=Yojson.Safe.Util.member "turns" history |> Yojson.Safe.Util.to_list in
  let turn=List.hd turns |> set "bundle" (`String (bundle:>string)) |> set "messages" (`Int count) in
  let history=history |> set "segment" `Null |> set "open" (`List []) |> set "turns" (`List [turn]) in
  error_pair (Yojson.Safe.to_string (set "history" history json)) table
let () =
  check "64-bit fixture" (Sys.word_size=64);
  let slice payload =
    let old=Codec_before.decode_written_bytes ~decode:(fun json->Ok json) payload in
    let new_=Codec_after.decode_written_slice ~decode:(fun json->Ok json)
      ("prefix"^payload^"suffix") ~off:6 ~len:(String.length payload) in
    check "bounded slice same wire AST/error" (old=new_) in
  List.iter slice ["";" ";"null";"[]";"{}";"1 2";"[1,]";"{\"a\":}";
    "\"unterminated";"1e999";"-0.0";"123456789012345678901234567890";"{\"a\":1,\"a\":2}"];
  List.iter (fun n ->
    slice ("[" ^ String.make n ' ' ^ "x012345678901234567890123456789012345678901234567890123456789");
    slice ("\"" ^ String.make n 'a' ^ "\\qtail012345678901234567890123456789012345678901234567890123456789");
    slice ("\"" ^ String.make n 'a' ^ "\"")) [1;1000;1018;1020;1022;1023;1024;1025;2047;2048;4096];
  let cases=List.map (fun (count,size)->scenario count size) [1,0;1,16;8,128;4,65536;4,262144] in
  let head,table=fixture 1 32 in
  let samples=["";" ";"null";"[]";"{}";"1 2";"[1,]";"{\"a\":}";"\"unterminated"] in
  List.iter (fun payload->malformed_bundle head table payload "" 1) samples;
  List.iter (fun n ->
    malformed_bundle head table ("[" ^ String.make n ' ' ^ "x012345678901234567890123456789012345678901234567890") "" 1;
    malformed_bundle head table ("\"" ^ String.make n 'a' ^ "\\qtail01234567890123456789012345678901234567890123456789") "" 1)
    [1000;1018;1020;1022;1023;1024;1025;2047;2048;4096];
  let valid=Codec_before.message_to_json (Types.make_message ~role:Types.User [Types.Text "valid"]) |> Yojson.Safe.to_string in
  malformed_bundle head table valid "extra" 1;
  malformed_bundle head table valid "" 2;
  malformed_bundle head table valid "" 1;
  let missing=Hashtbl.create 0 in error_pair head missing;
  let corrupt=Hashtbl.copy table in Hashtbl.iter (fun k _->Hashtbl.replace corrupt k "corrupt") table;error_pair head corrupt;
  let segmented,segments=fixture ~turns:(Before.turns_per_segment+2) 1 32 in
  error_pair segmented segments;
  let open_plan=get (Before.plan_save (Before.create_memo ()) Before.Turn_continues
    (checkpoint [Types.make_message ~role:Types.User [Types.Text "open message"]])) in
  let open_table=Hashtbl.create 4 in
  List.iter (fun ((digest:Before.digest),bytes)->Hashtbl.replace open_table (digest:>string) bytes) open_plan.objects;
  error_pair open_plan.head_bytes open_table;
  let memo=After.create_memo () and after_head=get (After.head_of_string head) in
  ignore (get (After.load memo ~read_object:(fun d->read table (d:>string)) after_head));
  let kept=After.memo_encoded_bytes memo in
  let failed=After.load memo ~read_object:(fun _->Error "synthetic unavailable") after_head in
  check "failed load returns same unreadable error" (match failed with
    | Error (After.Object_unreadable {detail;_}) -> detail="synthetic unavailable"
    | Ok _ | Error (Head_invalid _ | Checkpoint_invalid _ | Object_missing _
      | Object_digest_mismatch _ | Bundle_invalid _ | Turn_mismatch _ | Message_invalid _
      | Segment_invalid _ | Header_object_invalid _) -> false);
  check "failed load leaves previous memo intact" (kept>0 && kept=After.memo_encoded_bytes memo);
  print_endline (Yojson.Safe.to_string (`Assoc ["assertions",`Int !assertions;"cases",`List cases;
    "word_bits",`Int Sys.word_size;
    "gc_only_disposable_fixture",`Bool true]))
