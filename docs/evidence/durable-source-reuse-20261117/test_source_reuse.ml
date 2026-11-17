open Masc
open Fixture
module Before = Request_before
module After = Request_after
let after_owner root = get (After.owner_of_json (Before.owner_to_json (owner root)))
let fresh_record serialized =
  let reader=Owner.Published_reader.create ~read_body:(fun ~scope:_ ~request_digest:_ ->
    Ok (Some serialized.bytes)) in
  read reader serialized
let before root first second =
  let a=fresh_record first and b=fresh_record second in
  let x=get (Before.restore ~owner:(owner root) a) in
  let y=get (Before.restore ~owner:(owner root) b) in
  (a,x),(b,y)
let after root first second =
  let a=fresh_record first and b=fresh_record second in
  let x=get (After.restore ~owner:(after_owner root) a) in
  let y=get (After.restore_reusing_source ~previous:x ~owner:(after_owner root) b) in
  (a,x),(b,y)
let words value = Obj.reachable_words (Obj.repr value)
let allocated () = let minor,promoted,major=Gc.counters () in minor+.major-.promoted
let measure operation =
  Gc.full_major ();
  let allocated_before=allocated () and cpu_before=Sys.time () in
  let pair=operation () in
  let cpu=Sys.time ()-.cpu_before in
  let bytes=(allocated ()-.allocated_before)*.8. in
  ignore (Sys.opaque_identity pair);
  bytes,cpu,words pair
let replace_field name value = function
  | `Assoc fields -> `Assoc (List.map (fun (key,old) -> key,(if key=name then value else old)) fields)
  | _ -> failwith "fixture object"
let changed serialized f =
  let json=f (Yojson.Safe.from_string serialized.bytes) in
  let bytes=encode json in
  let digest=hash bytes in
  {serialized with bytes;digest;metadata=replace_field "request_digest" (`String digest) serialized.metadata}
let outcome encode = function Ok value -> `Ok (encode value) | Error detail -> `Error detail
let same_error root previous serialized =
  let record=fresh_record serialized in
  let left=outcome Before.to_json (Before.restore ~owner:(owner root) record) in
  let right=outcome After.to_json
    (After.restore_reusing_source ~previous ~owner:(after_owner root) record) in
  check "same full value or error" (left=right)
let source_change mutate json =
  let text=string (member "source_text" json) in
  replace_field "source_text" (`String (mutate text)) json
let trial root bytes =
  let first=serialize root bytes "019a8aa0-0000-7000-8000-000000000101" in
  let second=serialize root bytes "019a8aa0-0000-7000-8000-000000000102" in
  let ((_,bx),(_,by))=before root first second in
  let ((_,ax),(_,ay))=after root first second in
  check "baseline sources independently restored" (Before.source bx != Before.source by);
  check "candidate identical source shared" (After.source ax == After.source ay);
  check "first request value unchanged" (Before.to_json bx=After.to_json ax);
  check "second request value unchanged" (Before.to_json by=After.to_json ay);
  check "preparation binds exact shared input"
    ((After.preparation ay).source_input==Source.input (After.source ax));
  let cases=[second;
    changed second (source_change (fun value -> value ^ " "));
    changed second (source_change (fun _ -> "{"));
    changed second (source_change (fun value ->
      let json=Yojson.Safe.from_string value in
      Yojson.Safe.to_string (replace_field "purpose" (`String "wrong") json)));
    changed second (replace_field "kind" (`String "wrong"));
    changed second (replace_field "preparation" `Null)] in
  List.iter (same_error root ax) cases;
  let different=serialize root (bytes+1) "019a8aa0-0000-7000-8000-000000000103" in
  let _,(_,different_after)=after root first different in
  check "different full source does not share" (After.source ax != After.source different_after);
  same_error root ax different;
  let before_bytes,_,before_words=measure (fun () -> before root first second) in
  let after_bytes,_,after_words=measure (fun () -> after root first second) in
  let bench operation = let start=Sys.time () in
    for _=1 to 8 do ignore(Sys.opaque_identity(operation ())) done;Sys.time ()-.start in
  let rounds=List.init 4 (fun round ->
    let before_cpu,after_cpu=if round mod 2=0 then
      let before_cpu=bench(fun()->before root first second) in
      let after_cpu=bench(fun()->after root first second) in before_cpu,after_cpu
    else let after_cpu=bench(fun()->after root first second) in
      let before_cpu=bench(fun()->before root first second) in before_cpu,after_cpu in
    `Assoc["before",`Float before_cpu;"after",`Float after_cpu]) in
  `Assoc["payload_bytes",`Int bytes;"pair_allocated_bytes",`List[`Float before_bytes;`Float after_bytes];
    "pair_union_words",`List[`Int before_words;`Int after_words];"cpu_rounds_8_pairs",`List rounds]
let () =
  let parent=owned_root () in
  let root=Filename.concat parent "source" in Unix.mkdir root 0o700;
  let root=Unix.realpath root in
  let cases=List.map (trial root) [4096;262144] in
  let first=serialize root 4096 "019a8aa0-0000-7000-8000-000000000104" in
  let second=serialize root 4096 "019a8aa0-0000-7000-8000-000000000105" in
  let record=fresh_record first in
  let previous=get(After.restore ~owner:(after_owner root) record) in
  let record2=fresh_record second in
  let before_owner=owner root and after_owner=after_owner root in
  let moved=root ^ "-moved" in Unix.rename root moved;Unix.mkdir root 0o700;
  let left=outcome Before.to_json (Before.restore ~owner:before_owner record2) in
  let right=outcome After.to_json (After.restore_reusing_source ~previous ~owner:after_owner record2) in
  check "fresh physical root replacement still refused" (left=right && match right with `Error _ -> true | `Ok _ -> false);
  print_endline(Yojson.Safe.to_string(`Assoc["assertions",`Int !check_count;"cases",`List cases;
    "live_server_actions",`Bool false]))
