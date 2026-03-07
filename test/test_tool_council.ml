open Masc_mcp
open Alcotest

module Consensus = Council.Consensus

let test_counter = ref 0

let temp_dir prefix =
  incr test_counter;
  let dir = Filename.temp_file (Printf.sprintf "%s_%d_" prefix !test_counter) "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let parse_json_exn s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error e -> failwith ("invalid json: " ^ e)

let contains_substring ~needle haystack =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    idx + needle_len <= hay_len
    && ((String.sub haystack idx needle_len = needle) || loop (idx + 1))
  in
  needle_len = 0 || loop 0

let dispatch_exn ctx ~name ~args =
  match Tool_council.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

let make_ctx ~base_path ~agent_name : Tool_council.context =
  { base_path; agent_name; room_config = None }

let session_file base_path session_id =
  Filename.concat
    (Filename.concat (Filename.concat base_path ".masc") "consensus")
    (session_id ^ ".json")

let with_paths f =
  let target_base = temp_dir "test_tool_council_target" in
  let stale_base = temp_dir "test_tool_council_stale" in
  Fun.protect
    ~finally:(fun () ->
      Consensus.clear_sessions ();
      Consensus.init ~base_path:"/tmp/masc-test-consensus-noop";
      cleanup_dir target_base;
      cleanup_dir stale_base)
    (fun () -> f ~target_base ~stale_base)

let extract_session_id body =
  parse_json_exn body |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string

let test_consensus_start_uses_tool_base_path () =
  with_paths @@ fun ~target_base ~stale_base ->
  let ctx = make_ctx ~base_path:target_base ~agent_name:"alice" in
  Consensus.clear_sessions ();
  Consensus.init ~base_path:stale_base;
  let ok, body =
    dispatch_exn ctx ~name:"masc_consensus_start"
      ~args:(`Assoc [("topic", `String "Persist via tool"); ("quorum", `Int 2)])
  in
  check bool "start ok" true ok;
  let session_id = extract_session_id body in
  check bool "persisted to target base" true (Sys.file_exists (session_file target_base session_id));
  check bool "not persisted to stale base" false (Sys.file_exists (session_file stale_base session_id));
  Consensus.clear_sessions ();
  let ok, body = dispatch_exn ctx ~name:"masc_sessions" ~args:(`Assoc []) in
  check bool "sessions ok" true ok;
  let sessions = parse_json_exn body |> Yojson.Safe.Util.to_list in
  let has_session =
    List.exists
      (fun json ->
        Yojson.Safe.Util.member "id" json |> Yojson.Safe.Util.to_string = session_id)
      sessions
  in
  check bool "session restored by tool sessions" true has_session

let test_consensus_vote_reloads_persisted_session () =
  with_paths @@ fun ~target_base ~stale_base ->
  let starter = make_ctx ~base_path:target_base ~agent_name:"alice" in
  let voter = make_ctx ~base_path:target_base ~agent_name:"bob" in
  Consensus.clear_sessions ();
  let ok, body =
    dispatch_exn starter ~name:"masc_consensus_start"
      ~args:(`Assoc [("topic", `String "Persist vote"); ("quorum", `Int 2)])
  in
  check bool "start ok" true ok;
  let session_id = extract_session_id body in
  Consensus.clear_sessions ();
  Consensus.init ~base_path:stale_base;
  let ok, _body =
    dispatch_exn voter ~name:"masc_consensus_vote"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("decision", `String "approve");
            ("reason", `String "looks good");
          ])
  in
  check bool "vote ok" true ok;
  Consensus.clear_sessions ();
  Consensus.init ~base_path:target_base;
  match Consensus.get_session ~session_id with
  | None -> fail "session not restored from target base"
  | Some restored ->
      check int "vote count" 1 (List.length restored.Consensus.votes);
      let vote = List.hd restored.Consensus.votes in
      check string "vote agent" "bob" vote.Consensus.agent;
      check bool "decision approve" true (vote.Consensus.decision = Consensus.Approve)

let test_consensus_close_and_result_reload_persisted_session () =
  with_paths @@ fun ~target_base ~stale_base ->
  let starter = make_ctx ~base_path:target_base ~agent_name:"alice" in
  let voter = make_ctx ~base_path:target_base ~agent_name:"bob" in
  Consensus.clear_sessions ();
  let ok, body =
    dispatch_exn starter ~name:"masc_consensus_start"
      ~args:(`Assoc [("topic", `String "Persist close"); ("quorum", `Int 1)])
  in
  check bool "start ok" true ok;
  let session_id = extract_session_id body in
  let ok, _body =
    dispatch_exn voter ~name:"masc_consensus_vote"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("decision", `String "approve");
            ("reason", `String "ship it");
          ])
  in
  check bool "vote ok" true ok;
  Consensus.clear_sessions ();
  Consensus.init ~base_path:stale_base;
  let ok, _body =
    dispatch_exn starter ~name:"masc_consensus_close"
      ~args:(`Assoc [("session_id", `String session_id)])
  in
  check bool "close ok" true ok;
  Consensus.clear_sessions ();
  Consensus.init ~base_path:stale_base;
  let ok, body =
    dispatch_exn starter ~name:"masc_consensus_result"
      ~args:(`Assoc [("session_id", `String session_id)])
  in
  check bool "result ok" true ok;
  check bool "result mentions approved" true (contains_substring ~needle:"approved" body)

let () =
  run "Tool_council" [
    ("consensus_persistence", [
      test_case "start uses tool base path" `Quick test_consensus_start_uses_tool_base_path;
      test_case "vote reloads persisted session" `Quick test_consensus_vote_reloads_persisted_session;
      test_case "close and result reload persisted session" `Quick test_consensus_close_and_result_reload_persisted_session;
    ]);
  ]
