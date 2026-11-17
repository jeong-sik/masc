open Masc
open Fixture
open Reuse_helpers
let get_after root serialized =
  get (After.restore ~owner:(after_owner root) (fresh_record serialized))
let metadata_summary serialized f =
  {serialized with metadata=replace_field "summary" (canonical(f(member "summary" serialized.metadata))) serialized.metadata}
let () =
  let root=Unix.realpath(owned_root ()) in
  let first=serialize root 65536 "019a8aa0-0000-7000-8000-000000000201" in
  let second=serialize root 65536 "019a8aa0-0000-7000-8000-000000000202" in
  let previous=get_after root first in
  let record=fresh_record second in
  let pure=get(After.of_json ~owner:(after_owner root) (Yojson.Safe.from_string first.bytes)) in
  let from_pure=get(After.restore_reusing_source ~previous:pure ~owner:(after_owner root) record) in
  check "of_json seed reuses only its validated source" (After.source pure==After.source from_pure);
  let source=source root 65536 in
  let created=get(After.create ~request_id:first.id ~owner:(after_owner root) ~destination
    ~source ~preparation:(preparation(Source.input source)) ()) in
  let from_created=get(After.restore_reusing_source ~previous:created ~owner:(after_owner root) record) in
  check "create seed reuses only its canonical source" (After.source created==After.source from_created);
  let changed_time=changed second (fun json ->
    replace_field "preparation" (replace_field "parsing_now" (`Float 2.) (member "preparation" json)) json) in
  same_error root previous changed_time;
  let timed=get(After.restore_reusing_source ~previous ~owner:(after_owner root) (fresh_record changed_time)) in
  check "valid new preparation is fresh" ((After.preparation timed).parsing_now=2.);
  check "valid new preparation still shares identical source" (After.source timed==After.source previous);
  let predecessor=`Assoc["request_id",`String first.id;"request_digest",`String first.digest] in
  let linked=changed second (replace_field "predecessor" predecessor)
    |> fun value -> metadata_summary value (replace_field "predecessor" predecessor) in
  same_error root previous linked;
  let linked=get(After.restore_reusing_source ~previous ~owner:(after_owner root) (fresh_record linked)) in
  check "new predecessor preserved" (match After.predecessor linked with
    | Some p -> p.request_id=first.id && p.request_digest=first.digest | None -> false);
  let wrong_index=metadata_summary second (replace_field "exact_digest" (`String(String.make 64 '0'))) in
  same_error root previous wrong_index;
  check "changed index refused" (match After.restore_reusing_source ~previous ~owner:(after_owner root)
    (fresh_record wrong_index) with Error _ -> true | Ok _ -> false);
  let wrong_binding=changed second (replace_field "request_id" (`String first.id)) in
  same_error root previous wrong_binding;
  let new_owner_json=replace_field "epoch" (`String "another-epoch") (Before.owner_to_json(owner root)) in
  let new_epoch=changed second (replace_field "owner" new_owner_json)
    |> fun value -> metadata_summary value (replace_field "owner" new_owner_json) in
  let retained=fresh_record new_epoch in
  let before_owner=get(Before.owner_of_json new_owner_json) in
  let after_owner=get(After.owner_of_json new_owner_json) in
  let old_result=get(Before.restore ~owner:before_owner retained) in
  let new_result=get(After.restore_reusing_source ~previous ~owner:after_owner retained) in
  check "changed supplied owner preserves value" (Before.to_json old_result=After.to_json new_result);
  check "different captured owner does not share source" (After.source new_result!=After.source previous);
  print_endline(Yojson.Safe.to_string(`Assoc["assertions",`Int !check_count;"whole_source_api",`Bool true]))
