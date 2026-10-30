open Alcotest
open Masc
module H = Machine_input_history
module Retain = Lane_addon_machine_history
module Store = Lane_addon_store
module T = Lane_addon_types
module S = Mcp_protocol.Mcp_types
let unwrap = function Ok value -> value | Error detail -> fail detail
let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path
let record n = `Assoc ["number",`Int n;"input",`String (String.make 512 'x')]
let captured descriptor : T.output = {
  rows=[{id="screen";lane_id="machine/screen";kind=T.Value;title="machine";
    observed_at=1.;subject_id="machine";clock=None;actor=None;
    fields=["input_history",descriptor];evidence=[];related_ids=[]}];coverage=[]}
let ledger output =
  let row = List.hd output.T.rows in
  check bool "transfer descriptor is not published as model context" false (List.mem_assoc "input_history" row.fields);
  let fields = Yojson.Safe.Util.to_assoc (List.assoc "input_ledger" row.fields) in
  let reference = unwrap (T.evidence_of_json (List.assoc "evidence" fields)) in
  check bool "ledger is declared as retained row evidence" true (List.mem reference row.evidence);
  reference
let jsonl entries = String.concat "" (List.map (fun json -> Yojson.Safe.to_string json ^ "\n") entries)
let test_transfer () =
  let directory = Filename.temp_dir "machine-history-" "" in
  Fun.protect ~finally:(fun () -> remove_tree directory) (fun () ->
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let store = Store.create ~root:(Filename.concat directory "artifacts") in
    let worker = H.create ~encode:Fun.id () in
    let host = Retain.create () in
    let calls = ref [] in
    let fail_at = ref None in
    let call ~name ~arguments =
      check string "private history port" H.tool_name name;
      let before = Yojson.Safe.Util.(arguments |> member "before" |> to_int) in
      calls := before :: !calls;
      if !fail_at = Some before then Error "fixture response lost"
      else H.read worker ~arguments |> Result.map (fun json ->
        let result : S.tool_result = {content=[];is_error=Some false;structured_content=Some json;_meta=None} in
        let wire = Mcp_protocol.Jsonrpc.make_response_json ~id:(Mcp_protocol.Jsonrpc.Int min_int)
          ~result:(S.tool_result_to_yojson result) |> Yojson.Safe.to_string in
        check bool "full JSON-RPC reply and newline fit the transport envelope" true (String.length wire + 1 <= 1024);
        result) in
    let retain ?(instance_id="worker-a") output = Retain.retain host ~store ~instance_id
      ~max_response_bytes:1024 ~call output in
    let publish entries = H.publish worker ~incarnation:"load-1" ~entry_count:(List.length entries)
      ~newest_first:entries |> captured in
    let first = unwrap (retain (publish [record 3;record 2;record 1])) in
    let first_reference = ledger first in
    check (list int) "large records transfer as three cursor pages" [3;2;1] (List.rev !calls);
    check string "retained sequence is oldest first" (jsonl [record 1;record 2;record 3])
      (unwrap (Store.read_jsonl store first_reference));
    calls := [];
    let repeated = unwrap (retain (publish [record 3;record 2;record 1])) in
    check (list int) "completed prefix needs no transfer" [] !calls;
    check bool "same input prefix keeps its immutable evidence" true (ledger repeated = first_reference);
    let next = publish [record 5;record 4;record 3;record 2;record 1] in
    fail_at := Some 4;
    check bool "partial transfer is not published" true (Result.is_error (retain next));
    check string "failed transfer leaves prior evidence readable" (jsonl [record 1;record 2;record 3])
      (unwrap (Store.read_jsonl store first_reference));
    calls := []; fail_at := None;
    let next_reference = ledger (unwrap (retain next)) in
    check (list int) "retry fetches only the uncommitted suffix" [5;4] (List.rev !calls);
    check string "append has no duplicate or missing input" (jsonl [record 1;record 2;record 3;record 4;record 5])
      (unwrap (Store.read_jsonl store next_reference));
    let foreign = publish [record 8] in
    let foreign_reference = ledger (unwrap (retain ~instance_id:"worker-b" foreign)) in
    check string "another worker cannot share a cursor by naming the same incarnation" (jsonl [record 8])
      (unwrap (Store.read_jsonl store foreign_reference));
    check bool "cursor regression needs a fresh incarnation" true (Result.is_error (retain foreign));
    let unavailable_root = Filename.concat directory "blocked-artifacts" in
    Out_channel.with_open_bin unavailable_root (fun channel -> output_string channel "not a directory");
    let unavailable_store = Store.create ~root:unavailable_root in
    let retry_host = Retain.create () in
    let retry () = Retain.retain retry_host ~store:unavailable_store ~instance_id:"worker-d"
      ~max_response_bytes:1024 ~call foreign in
    check bool "failed durable write cannot publish a ledger" true (Result.is_error (retry ()));
    Unix.unlink unavailable_root; calls := [];
    let recovered = ledger (unwrap (retry ())) in
    check (list int) "failed durable write does not advance transfer cursor" [1] !calls;
    check string "repaired store receives the complete prefix" (jsonl [record 8])
      (unwrap (Store.read_jsonl unavailable_store recovered));
    let forged ~name:_ ~arguments:_ = Ok {S.content=[];is_error=Some false;_meta=None;
      structured_content=Some (`Assoc ["incarnation",`String "wrong";"entry_count",`Int 1;
        "before",`Int 1;"next_before",`Int 0;"entries",`List [record 9]])} in
    check bool "foreign page cannot become retained evidence" true
      (Result.is_error (Retain.retain (Retain.create ()) ~store ~instance_id:"worker-c"
        ~max_response_bytes:1024 ~call:forged foreign)) ))
let () = run "machine input history"
  ["transfer",[test_case "paged immutable prefixes and partial failure" `Quick test_transfer]]
