open Alcotest
open Masc
module Store = Lane_addon_store
module Types = Lane_addon_types
let unwrap = function Ok value -> value | Error message -> fail message
let rec remove path =
  if Sys.is_directory path then (Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path)
  else Sys.remove path
let with_store f =
  let root = Filename.temp_dir "lane-query-" "" in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root (Store.create ~root))
let instance_id = "test-instance"
let row seq payload : Types.row = {
  id = Printf.sprintf "%s/%d/row" instance_id seq;
  lane_id = instance_id ^ "/source"; kind = Types.Event; title = "retained observation";
  observed_at = float_of_int seq; subject_id = "existing-target";
  clock = None; actor = None; fields = ["payload", `String payload];
  evidence = []; related_ids = [];
}
let append store seq payload =
  unwrap (Store.append_observation store ~instance_id ~seq ~sources:(`List [])
    { rows = [row seq payload]; coverage = [] })
let query store ~expected_seq ~max_bytes ?since ?until () =
  unwrap (Store.query_observations store ~instance_id ~expected_seq ~max_bytes ~since ~until ~lane_id:None)
let complete output = List.for_all (fun (coverage : Types.coverage) -> coverage.complete) output.Types.coverage
let binding max_bytes = `Assoc ["package", `Assoc ["resources", `Assoc ["max_reply_bytes", `Int max_bytes]]]
let record root seq = Filename.concat root (Printf.sprintf "observations/%s/%020d.json" (Store.digest instance_id) seq)
let write path text = let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel text)

let bounded_history () = with_store (fun _root store ->
  for seq = 1 to 24 do append store seq (String.make 1000 'x') done;
  let max_bytes = 4096 in
  let output = query store ~expected_seq:24 ~max_bytes () in
  check bool "some history fits" true (output.rows <> []);
  check bool "large history is explicitly partial" false (complete output);
  check bool "encoded response fits its declared bound" true
    (String.length (Yojson.Safe.to_string (Types.output_to_json output)) <= max_bytes);
  let late = query store ~expected_seq:24 ~max_bytes ~since:24. () in
  check int "window selection does not retain earlier bodies" 1 (List.length late.rows);
  check bool "complete filtered scan" true (complete late))
let missing_record () = with_store (fun root store ->
  append store 1 "one"; append store 2 "two"; append store 3 "three";
  Sys.remove (record root 2);
  let output = query store ~expected_seq:3 ~max_bytes:4096 () in
  check int "readable records retained" 2 (List.length output.rows);
  check bool "missing interval is not complete" false (complete output);
  Sys.remove (record root 3);
  Sys.remove (record root 1);
  let empty = query store ~expected_seq:3 ~max_bytes:4096 () in
  check bool "persisted highwater exposes missing entire history" false (complete empty))
let targeted_evidence () = with_store (fun root store ->
  append store 1 "unrelated"; append store 2 "selected";
  write (record root 1) "{broken unrelated observation";
  let frozen = Store.freeze store ~instance_id ~binding:(binding 4096)
    ~row_ids:[(row 2 "").id] in
  check bool "selected evidence does not scan corrupt unrelated history" true (Result.is_ok frozen);
  check bool "different instance rejected" true
    (Result.is_error (Store.freeze store ~instance_id ~binding:(binding 4096) ~row_ids:["other/2/row"]));
  check bool "evidence envelope enforced" true
    (Result.is_error (Store.freeze store ~instance_id ~binding:(binding 64) ~row_ids:[(row 2 "").id])))
let separate_source_and_output_envelopes () = with_store (fun root store ->
  let max_bytes = 4096 in
  let sources = `List [`String (String.make 3000 's')] in
  let output : Types.output = { rows = [row 1 (String.make 3000 'o')]; coverage = [] } in
  unwrap (Store.append_observation store ~instance_id ~seq:1 ~sources output);
  let original = In_channel.with_open_bin (record root 1) In_channel.input_all in
  check bool "valid record exceeds one component envelope" true (String.length original > max_bytes);
  let queried = query store ~expected_seq:1 ~max_bytes () in
  check int "both bounded components remain queryable" 1 (List.length queried.rows);
  let frozen = unwrap (Store.freeze store ~instance_id ~binding:(binding max_bytes) ~row_ids:[(row 1 "").id]) in
  let open Yojson.Safe.Util in
  let bundle_path = frozen |> member "evidence" |> member "path" |> to_string in
  let bundle = In_channel.with_open_bin bundle_path In_channel.input_all |> Yojson.Safe.from_string in
  let retained = bundle |> member "observations" |> to_list |> List.hd in
  Sys.remove (record root 1);
  let retained_bytes = In_channel.with_open_bin (retained |> member "path" |> to_string) In_channel.input_all in
  check string "exact record bytes survive original history deletion" original retained_bytes;
  check string "retained record digest matches" (Store.digest original) (retained |> member "sha256" |> to_string))
let () = run "bounded Lane history" ["queries", [
  test_case "history growth and explicit window" `Quick bounded_history;
  test_case "missing persisted intervals" `Quick missing_record;
  test_case "targeted bounded evidence" `Quick targeted_evidence;
  test_case "separate ingress and egress envelopes remain preservable" `Quick separate_source_and_output_envelopes]]
