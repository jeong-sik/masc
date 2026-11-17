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
