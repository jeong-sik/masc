open Masc
open Fixture
module Store = Lane_addon_store
module Before = Batch_before
module After = Batch_after
module Request = Request_after
let get_owner = function Ok value -> value | Error error -> failwith(Owner.error_to_string error)
let get_result = function Ok value -> value | Error error -> failwith(Lane_addon_submit_once.error_to_string error)
let keep store serialized =
  get_owner(Owner.retain ~store ~scope:serialized.scope ~request_id:serialized.id
    ~installation_id:destination.installation_id ~package_id:destination.package_id ~tool:destination.tool
    ~summary:(member "summary" serialized.metadata) ~request:(Yojson.Safe.from_string serialized.bytes))
let record store serialized =
  match get_owner(Owner.load ~store ~scope:serialized.scope ~request_id:serialized.id) with
  | Some retained -> Owner.listed retained | None -> failwith "retained fixture absent"
let before_list store records =
  let listed=List.map(fun record -> record,get(Request_before.index_of_summary record))records in
  let reversed=List.fold_left(fun result original ->
    Result.bind result (fun found -> Result.map(fun value -> value::found) (Before.load ~store original))) (Ok []) listed in
  Result.map List.rev reversed
let after_list store records =
  let listed=List.map(fun record -> record,get(Request.index_of_summary record))records in
  After.load_many ~store listed
let json_before (record,request) = Owner.to_json record,Request_before.to_json request
let json_after (record,request) = Owner.to_json record,Request.to_json request
let outcome convert = function
  | Ok values -> `Ok(List.map convert values)
  | Error error -> `Error(Lane_addon_submit_once.error_to_string error)
let compare label store records =
  Before.io_count:=0;After.io_count:=0;
  let a=before_list store records and b=after_list store records in
  check(label^" exact result/error") (outcome json_before a=outcome json_after b);
  check(label^" fresh IO boundaries") (!(Before.io_count)= !(After.io_count));
  a,b
let write path bytes = let channel=open_out_bin path in output_string channel bytes;close_out channel
let allocated () = let minor,promoted,major=Gc.counters () in minor+.major-.promoted
let measure operation =
  Gc.full_major ();
  let before=allocated () in
  let values=get_result(operation ()) in
  let bytes=(allocated ()-.before)*.8. in
  ignore(Sys.opaque_identity values);bytes
let[@inline never] released_source store records =
  let values=get_result(after_list store records) in
  let witness=Weak.create 1 in
  Weak.set witness 0 (Some(Source.input(Request.source(snd(List.hd values)))));
  witness
let () =
  let root=Unix.realpath(owned_root ()) in
  let store=Store.create ~root:(Filename.concat root "store") in
  let first=serialize root 65536 "019a8aa0-0000-7000-8000-000000000301" in
  let second=serialize root 65536 "019a8aa0-0000-7000-8000-000000000302" in
  let third=serialize root 65537 "019a8aa0-0000-7000-8000-000000000303" in
  List.iter(keep store)[first;second;third];
  let records=List.map(record store)[first;second;third] in
  ignore(compare "empty" store []);
  let a,b=compare "ordered mixed sources" store records in
  let baseline=get_result a and candidate=get_result b in
  let before_a=snd(List.nth baseline 0) and before_b=snd(List.nth baseline 1) in
  let after_a=snd(List.nth candidate 0) and after_b=snd(List.nth candidate 1) in
  check "baseline sources separate" (Request_before.source before_a!=Request_before.source before_b);
  check "batch identical source shared" (Request.source after_a==Request.source after_b);
  check "batch distinct source not shared" (Request.source after_a!=Request.source(snd(List.nth candidate 2)));
  let again=get_result(after_list store records) in
  check "no source cache across batches" (Request.source after_a!=Request.source(snd(List.hd again)));
  let witness=released_source store records in
  Gc.full_major ();Gc.full_major ();
  check "batch hint map releases the restored source" (not(Weak.check witness 0));
  ignore(compare "reversed order" store (List.rev records));
  ignore(compare "duplicate records retain read order" store [List.hd records;List.hd records]);
  let collisions=serialize root 65538 "019a8aa0-0000-7000-8000-000000000304" in
  let first_digest=member "source_digest" (member "summary" first.metadata) in
  let summary=canonical(Reuse_helpers.replace_field "source_digest" first_digest (member "summary" collisions.metadata)) in
  let collisions={collisions with metadata=Reuse_helpers.replace_field "summary" summary collisions.metadata} in
  keep store collisions;
  let _,collision=compare "equal summary digest with different source text" store [List.hd records;record store collisions] in
  let values=get_result collision in
  check "summary lookup cannot substitute another source"
    (Request.source(snd(List.nth values 0))!=Request.source(snd(List.nth values 1)));
  let unique=List.init 8(fun i ->
    serialize root (4096+i) (Printf.sprintf "019a8aa0-0000-7000-8000-%012d" (310+i))) in
  List.iter(keep store)unique;
  let unique_records=List.map(record store)unique in
  ignore(compare "all distinct sources" store unique_records);
  ignore(get_result(before_list store unique_records));ignore(get_result(after_list store unique_records));
  let unique_allocation=List.init 4(fun round ->
    let before,after=if round mod 2=0 then
      let before=measure(fun()->before_list store unique_records) in
      let after=measure(fun()->after_list store unique_records) in before,after
    else let after=measure(fun()->after_list store unique_records) in
      let before=measure(fun()->before_list store unique_records) in before,after in
    `List[`Float before;`Float after]) in
  let retained=match get_owner(Owner.load ~store ~scope:second.scope ~request_id:second.id) with
    | Some value -> value | None -> failwith "fixture missing" in
  (match Owner.advance_events ~store ~expected:retained ~events:[Lane_addon_request_progress.Dispatch_intended] with
   | Ok(Owner.Stored _|Already_stored _) -> ()
   | Ok(Unconfirmed detail) -> failwith detail
   | Error error -> failwith(Owner.update_error_to_string error));
  let _,fresh=compare "new progress after discovery" store records in
  let read,_=List.nth(get_result fresh)1 in
  check "new progress returned on a source hit" (match Lane_addon_request_progress.phase read.Owner.progress with
    | Dispatch_pending _ -> true
    | Captured|Admission_wait _|Judged _|Committing _|Commit_unknown _|Finished _|Conflicted _
    | Rejected _|Subdividing _|Subdivided _ -> false);
  let path=Filename.concat(Store.root store)(Store.tool_request_body_path ~scope:second.scope ~request_digest:second.digest) in
  write path "corrupt";
  let _,failed=compare "corrupt second body after source hit" store records in
  check "body corruption refused" (match failed with Error _ -> true | Ok _ -> false);
  check "stops before third body" (!(After.io_count)=3);
  write path second.bytes;
  ignore(compare "body restored" store records);
  Unix.unlink path;
  let _,missing=compare "missing second body after source hit" store records in
  check "missing body refused" (match missing with Error _ -> true | Ok _ -> false);
  check "missing body stops later reads" (!(After.io_count)=3);
  print_endline(Yojson.Safe.to_string(`Assoc["assertions",`Int !check_count;
    "eight_unique_source_allocated_bytes",`List unique_allocation;
    "real_owned_store_io",`Bool true;"scope",`String "complete original load/load_many function bodies"] ))
