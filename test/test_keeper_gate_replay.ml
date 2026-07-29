(* RFC-0356: the replayed write must carry the approved payload, not a
   payload the model re-emits. These cases pin the reconstruction from a
   stored Gate input to the write tool arguments. *)

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let result_json =
  Alcotest.result json (Alcotest.testable Fmt.string String.equal)
;;

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_gate_replay_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec remove path =
    if Sys.is_directory path
    then (
      Array.iter
        (fun name -> remove (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  try remove dir with
  | Sys_error _ -> ()
;;

(* The pinned resource identity stays in the approved input and is
   deliberately absent from the reconstructed arguments: the write handler
   re-derives it, so a target replaced between approval and replay produces a
   different canonical input and the approval no longer matches. *)
let approved_content_input =
  `Assoc
    [ ( "effect"
      , `Assoc
          [ "operation", `String "atomic_replace_entry"
          ; ( "target_resource"
            , `Assoc [ "device", `Intlit "16777232"; "inode", `Intlit "94211" ]
            )
          ] )
    ; "requested_target", `String "/playground/executor/repos/masc/a.ml"
    ; "content", `String "let a = 1\n"
    ]
;;

let approved_edit_input =
  `Assoc
    [ "effect", `Assoc [ "operation", `String "patch_then_atomic_replace_entry" ]
    ; "requested_target", `String "/playground/executor/repos/masc/b.ml"
    ; "content", `String ""
    ; "old_string", `String "let b = 1"
    ; "new_string", `String "let b = 2"
    ; "replace_all", `Bool true
    ]
;;

let test_content_write () =
  Alcotest.check
    result_json
    "content write keeps the approved target and payload"
    (Ok
       (`Assoc
           [ "path", `String "/playground/executor/repos/masc/a.ml"
           ; "mode", `String "overwrite"
           ; "content", `String "let a = 1\n"
           ]))
    (Masc.Keeper_tool_filesystem_runtime.replay_args_of_gate_input
       approved_content_input)
;;

let test_edit_write () =
  Alcotest.check
    result_json
    "edit write carries old_string, new_string, and replace_all"
    (Ok
       (`Assoc
           [ "path", `String "/playground/executor/repos/masc/b.ml"
           ; "mode", `String "patch"
           ; "content", `String ""
           ; "old_string", `String "let b = 1"
           ; "new_string", `String "let b = 2"
           ; "replace_all", `Bool true
           ]))
    (Masc.Keeper_tool_filesystem_runtime.replay_args_of_gate_input
       approved_edit_input)
;;

(* A content write must not acquire edit fields: reconstruction carries only
   what the approval contained, so replay cannot widen the approved effect. *)
let test_absent_fields_are_not_invented () =
  match
    Masc.Keeper_tool_filesystem_runtime.replay_args_of_gate_input
      approved_content_input
  with
  | Error detail -> Alcotest.fail detail
  | Ok (`Assoc fields) ->
    List.iter
      (fun name ->
         Alcotest.check
           Alcotest.bool
           (Printf.sprintf "%s absent" name)
           false
           (List.mem_assoc name fields))
      [ "old_string"; "new_string"; "replace_all" ]
  | Ok _ -> Alcotest.fail "reconstructed arguments are not an object"
;;

(* An approved append must not replay as an overwrite: the mode arg defaults
   to overwrite, so dropping it would destroy the file the operator approved
   appending to. *)
let approved_append_input =
  `Assoc
    [ "effect", `Assoc [ "operation", `String "append_pinned_resource" ]
    ; "requested_target", `String "/playground/executor/repos/masc/log.txt"
    ; "content", `String "one more line\n"
    ]
;;

let test_append_stays_append () =
  Alcotest.check
    result_json
    "append mode survives the round trip"
    (Ok
       (`Assoc
           [ "path", `String "/playground/executor/repos/masc/log.txt"
           ; "mode", `String "append"
           ; "content", `String "one more line\n"
           ]))
    (Masc.Keeper_tool_filesystem_runtime.replay_args_of_gate_input
       approved_append_input)
;;

let test_unreproducible_effect_is_rejected () =
  match
    Masc.Keeper_tool_filesystem_runtime.replay_args_of_gate_input
      (`Assoc
          [ "effect", `Assoc [ "operation", `String "create_entry_exclusive" ]
          ; "requested_target", `String "/playground/executor/new.txt"
          ; "content", `String "x"
          ])
  with
  | Ok _ ->
    Alcotest.fail "an effect this module cannot reproduce must not replay"
  | Error _ -> ()
;;

let test_missing_target_is_rejected () =
  match
    Masc.Keeper_tool_filesystem_runtime.replay_args_of_gate_input
      (`Assoc [ "content", `String "orphan" ])
  with
  | Ok _ -> Alcotest.fail "input without requested_target must not reconstruct"
  | Error _ -> ()
;;

let test_non_object_input_is_rejected () =
  match
    Masc.Keeper_tool_filesystem_runtime.replay_args_of_gate_input
      (`String "opaque")
  with
  | Ok _ -> Alcotest.fail "non-object input must not reconstruct"
  | Error _ -> ()
;;


(* [tool_execute] dominates live approvals and had no host replay until now,
   so a Keeper had to re-emit a byte-identical command to spend its own
   approval. Unlike the write path nothing is reconstructed: the Gate request
   wraps the arguments with execution context instead of re-encoding them.

   The submitting handler upserts the resolved [cwd] into the arguments before
   wrapping them (keeper_tool_execute_runtime.ml), so every approved execute
   carries it twice: once inside [input] and once in the envelope. This fixture
   reproduces that shape — 130 of 130 pending [tool_execute] entries in the
   2026-07-28 store had [input.cwd], with no exceptions. A fixture without it
   passes assertions the producer can never satisfy. *)
let approved_execute_input =
  `Assoc
    [ "schema", `String "masc.keeper_gate.request.v1"
    ; ( "input"
      , `Assoc
          [ "argv", `List [ `String "git"; `String "status" ]
          ; "timeout_sec", `Int 30
          ; "cwd", `String "/repo"
          ] )
    ; "cwd", `String "/repo"
    ; "sandbox_profile", `String "docker"
    ; "sandbox_target", `String "docker:masc"
    ]
;;

let test_execute_args_are_the_approved_arguments () =
  Alcotest.check
    result_json
    "the approved arguments are replayed verbatim"
    (Ok
       (`Assoc
          [ "argv", `List [ `String "git"; `String "status" ]
          ; "timeout_sec", `Int 30
          ; "cwd", `String "/repo"
          ]))
    (Masc.Keeper_tool_execute_runtime.replay_args_of_gate_input
       approved_execute_input)
;;

(* The approved [cwd] is part of the effect the operator authorized, so it
   rides along inside the arguments. Dropping it would run the command in the
   current turn's default directory — an effect nobody approved. *)
let test_approved_cwd_is_replayed () =
  match
    Masc.Keeper_tool_execute_runtime.replay_args_of_gate_input
      approved_execute_input
  with
  | Error detail -> Alcotest.fail detail
  | Ok (`Assoc fields) ->
    Alcotest.check
      (Alcotest.option json)
      "the approved working directory reaches the replayed call"
      (Some (`String "/repo"))
      (List.assoc_opt "cwd" fields)
  | Ok _ -> Alcotest.fail "replayed execute arguments are not an object"
;;

(* The envelope siblings describe the sandbox the approval was granted under.
   The handler re-derives those and rebuilds the envelope, so a sandbox that
   moved since approval fails the canonical-input match instead of executing
   under a profile the approval never described. *)
let test_execute_envelope_is_not_replayed () =
  match
    Masc.Keeper_tool_execute_runtime.replay_args_of_gate_input
      approved_execute_input
  with
  | Error detail -> Alcotest.fail detail
  | Ok (`Assoc fields) ->
    List.iter
      (fun key ->
         Alcotest.check
           Alcotest.bool
           (key ^ " is not carried into the replayed arguments")
           false
           (List.mem_assoc key fields))
      [ "sandbox_profile"; "sandbox_target"; "schema" ]
  | Ok _ -> Alcotest.fail "replayed execute arguments are not an object"
;;

let test_execute_without_input_is_rejected () =
  match
    Masc.Keeper_tool_execute_runtime.replay_args_of_gate_input
      (`Assoc [ "cwd", `String "/repo" ])
  with
  | Ok _ -> Alcotest.fail "a Gate input with no arguments replayed anyway"
  | Error _ -> ()
;;

let approved_web_search_input =
  `Assoc
    [ "capability", `String "web_search"
    ; ( "input"
      , `Assoc
          [ "query", `String "approved exact search"
          ; "limit", `Int 1
          ] )
    ]
;;

let test_network_read_preserves_exact_web_search_arguments () =
  match
    Masc.Keeper_tool_in_process_runtime.network_read_replay_of_gate_input
      approved_web_search_input
  with
  | Ok
      (Masc.Keeper_tool_in_process_runtime.Replay_web_search
         (`Assoc
           [ "query", `String "approved exact search"
           ; "limit", `Int 1
           ])) ->
    ()
  | Ok _ -> Alcotest.fail "approved WebSearch arguments changed during decode"
  | Error detail -> Alcotest.fail detail
;;

let test_network_read_rejects_unknown_capability () =
  match
    Masc.Keeper_tool_in_process_runtime.network_read_replay_of_gate_input
      (`Assoc
        [ "capability", `String "invented"
        ; "input", `Assoc [ "query", `String "must not run" ]
        ])
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unknown network_read capability became replayable"
;;

let test_network_read_rejects_unknown_envelope_fields () =
  match
    Masc.Keeper_tool_in_process_runtime.network_read_replay_of_gate_input
      (`Assoc
        [ "capability", `String "web_search"
        ; "input", `Assoc [ "query", `String "must stay exact" ]
        ; "fallback", `String "invented"
        ])
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unknown network_read envelope field was ignored"
;;

let test_applied_replay_result_is_model_visible () =
  let output = {|{"results":[{"title":"durable"}]}|} in
  let message =
    Masc.Keeper_gate_replay.append_model_evidence
      ~approval_id:"approval-1"
      ~user_message:"continue"
      (Masc.Keeper_gate_replay.Applied
         { operation = "network_read"
         ; output
         ; journal = Masc.Keeper_gate_replay.Replay_journal_recorded
         })
  in
  let evidence =
    message
    |> String.split_on_char '\n'
    |> List.rev
    |> List.hd
    |> Yojson.Safe.from_string
  in
  Alcotest.check
    Alcotest.string
    "exact replay evidence reaches the current model turn"
    output
    Yojson.Safe.Util.(
      evidence |> member "untrusted_tool_output" |> to_string);
  Alcotest.check
    Alcotest.bool
    "current model turn cannot request the approved effect again"
    true
    (String_util.contains_substring
       message
       "Do not request the approved operation again")
;;

let test_large_replay_result_reaches_model_exactly () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let raw_output =
         "LARGE-REPLAY-BEGIN\n"
         ^ String.make (512 * 1024) 'x'
         ^ "\nLARGE-REPLAY-END"
       in
       let artifact =
         match
           Masc.Keeper_gate_replay.For_testing.persist_replay_artifact
             ~base_path
             raw_output
         with
         | Ok artifact -> artifact
         | Error detail -> Alcotest.fail detail
       in
       Alcotest.check
         Alcotest.int
         "artifact retains exact byte count"
         (String.length raw_output)
         artifact.bytes;
       let store = Tool_blob_store.create ~base_path in
       (match Tool_blob_store.fetch store ~sha256:artifact.sha256 with
        | Ok (Some restored) ->
          Alcotest.check
            Alcotest.string
            "artifact restores full replay output"
            raw_output
            restored
        | Ok None -> Alcotest.fail "replay artifact is missing"
        | Error error ->
          Alcotest.fail (Tool_blob_store.fetch_error_to_string error));
       let outcome =
         Masc.Keeper_gate_replay.For_testing.durable_replay_outcome
           ~base_path
           ~operation:"network_read"
           ~journal:Masc.Keeper_gate_replay.Replay_journal_recorded
           (Masc.Keeper_approval_queue.Replay_applied artifact)
       in
       let message =
         Masc.Keeper_gate_replay.append_model_evidence
           ~approval_id:"approval-large"
           ~user_message:"continue"
           outcome
       in
       let rendered_output =
         message
         |> String.split_on_char '\n'
         |> List.rev
         |> List.hd
         |> Yojson.Safe.from_string
         |> Yojson.Safe.Util.member "untrusted_tool_output"
         |> Yojson.Safe.Util.to_string
       in
       (* Above the ordinary-tool externalize threshold the rendered turn
          carries the standard blob marker, never the raw half-megabyte body:
          an unbounded injection re-enters the 07-29 request-cap x compaction
          incident class. The exact bytes stay durable (asserted above). *)
       (match Tool_output.decode_from_oas rendered_output with
        | Tool_output.Decoded rendered ->
          Alcotest.check
            Alcotest.string
            "rendered marker preserves artifact identity"
            artifact.sha256
            rendered.sha256;
          Alcotest.check
            Alcotest.int
            "rendered marker preserves byte count"
            artifact.bytes
            rendered.bytes
        | Tool_output.Not_marker ->
          Alcotest.fail "untrusted_tool_output is not a blob marker"
        | Tool_output.Invalid_marker { detail } ->
          Alcotest.failf "untrusted_tool_output has an invalid blob marker: %s" detail);
       Alcotest.check
         Alcotest.bool
         "raw oversized body does not enter the model turn"
         false
         (String_util.contains_substring message "LARGE-REPLAY-END");
       Alcotest.check
         Alcotest.bool
         "rendered turn stays bounded"
         true
         (String.length message < 16 * 1024))
;;

(* At or under the threshold the exact bytes are inlined — the small-output
   path is unchanged by the marker boundary. *)
let test_small_replay_result_is_inlined_exactly () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let raw_output = {|{"results":[{"title":"small-exact"}]}|} in
       let artifact =
         match
           Masc.Keeper_gate_replay.For_testing.persist_replay_artifact
             ~base_path
             raw_output
         with
         | Ok artifact -> artifact
         | Error detail -> Alcotest.fail detail
       in
       let message =
         Masc.Keeper_gate_replay.append_model_evidence
           ~approval_id:"approval-small"
           ~user_message:"continue"
           (Masc.Keeper_gate_replay.For_testing.durable_replay_outcome
              ~base_path
              ~operation:"network_read"
              ~journal:Masc.Keeper_gate_replay.Replay_journal_recorded
              (Masc.Keeper_approval_queue.Replay_applied artifact))
       in
       Alcotest.check
         Alcotest.bool
         "small evidence is inlined byte-exact"
         true
         (String_util.contains_substring message "small-exact");
       Alcotest.check
         Alcotest.bool
         "no marker below the threshold"
         false
         (String_util.contains_substring message Tool_output.marker_prefix))
;;


(* The decode functions above are only reachable if dispatch routes to them.
   An operation that has a decoder but is never dispatched to is
   indistinguishable from a working replay at the call site. *)
let test_dispatch_covers_all_replayable_operations () =
  let open Masc.Keeper_gate_replay in
  Alcotest.check
    Alcotest.bool
    "an approved filesystem_write is replayed"
    true
    (replayable_of_operation "filesystem_write" = Some Replay_write);
  Alcotest.check
    Alcotest.bool
    "an approved tool_execute is replayed"
    true
    (replayable_of_operation "tool_execute" = Some Replay_execute);
  Alcotest.check
    Alcotest.bool
    "an approved WebSearch/WebFetch network_read is replayed"
    true
    (replayable_of_operation "network_read" = Some Replay_network_read);
  Alcotest.check
    Alcotest.bool
    "an approved connector_post is host-replayed"
    true
    (replayable_of_operation "connector_post" = Some Replay_connector_post)
;;

let test_dispatch_refuses_unknown_operations () =
  let open Masc.Keeper_gate_replay in
  List.iter
    (fun operation ->
       Alcotest.check
         Alcotest.bool
         (operation ^ " has no replay continuation")
         true
         (replayable_of_operation operation = None))
    [ "keeper_board_post"; "" ]
;;

let test_large_connector_post_preserves_exact_durable_request () =
  let open Masc.Keeper_tool_in_process_runtime in
  let content =
    "CONNECTOR-BEGIN\n"
    ^ String.make (512 * 1024) 'x'
    ^ "\nCONNECTOR-END"
  in
  let blocks =
    [ `Assoc
        [ "type", `String "section"
        ; "text", `Assoc [ "type", `String "mrkdwn"; "text", `String content ]
        ]
    ]
  in
  let input =
    `Assoc
      [ "connector", `String "slack"
      ; "channel_id", `String "C-exact"
      ; "content", `String content
      ; "blocks", `List blocks
      ]
  in
  match
    Masc.Keeper_tool_in_process_runtime.connector_post_replay_of_gate_input
      input
  with
  | Ok
      (Replay_slack_post
         { input = decoded_input
         ; channel_id
         ; content = decoded_content
         ; blocks = decoded_blocks
         }) ->
    Alcotest.check json "exact durable request retained" input decoded_input;
    Alcotest.check Alcotest.string "channel retained" "C-exact" channel_id;
    Alcotest.check Alcotest.string "large content retained" content decoded_content;
    Alcotest.check
      (Alcotest.list json)
      "large blocks retained"
      blocks
      decoded_blocks
  | Ok (Replay_discord_post _) ->
    Alcotest.fail "Slack request decoded as Discord"
  | Error detail -> Alcotest.fail detail
;;

let test_connector_post_rejects_heuristic_or_truncated_input () =
  List.iter
    (fun input ->
       match
         Masc.Keeper_tool_in_process_runtime.connector_post_replay_of_gate_input
           input
       with
       | Error _ -> ()
       | Ok _ ->
         Alcotest.fail
           "incomplete or widened connector request became replayable")
    [ `Assoc
        [ "connector", `String "slack"
        ; "channel_id", `String "C-exact"
        ; "content", `String "missing exact blocks"
        ]
    ; `Assoc
        [ "connector", `String "discord"
        ; "channel_id", `String "D-exact"
        ; "content", `String "exact"
        ; "truncated", `Bool true
        ]
    ]
;;

let () =
  Alcotest.run
    "keeper_gate_replay"
    [ ( "filesystem producer replay decoder"
      , [ Alcotest.test_case "content write" `Quick test_content_write
        ; Alcotest.test_case "edit write" `Quick test_edit_write
        ; Alcotest.test_case
            "absent fields stay absent"
            `Quick
            test_absent_fields_are_not_invented
        ; Alcotest.test_case "append stays append" `Quick test_append_stays_append
        ; Alcotest.test_case
            "unreproducible effect rejected"
            `Quick
            test_unreproducible_effect_is_rejected
        ; Alcotest.test_case
            "missing target rejected"
            `Quick
            test_missing_target_is_rejected
        ; Alcotest.test_case
            "non-object rejected"
            `Quick
            test_non_object_input_is_rejected
        ] )
    ; ( "execute replay"
      , [ Alcotest.test_case
            "approved arguments replayed verbatim"
            `Quick
            test_execute_args_are_the_approved_arguments
        ; Alcotest.test_case
            "approved cwd is replayed"
            `Quick
            test_approved_cwd_is_replayed
        ; Alcotest.test_case
            "approval-time envelope is not replayed"
            `Quick
            test_execute_envelope_is_not_replayed
        ; Alcotest.test_case
            "input without arguments rejected"
            `Quick
            test_execute_without_input_is_rejected
        ] )
    ; ( "network read replay"
      , [ Alcotest.test_case
            "approved WebSearch arguments stay exact"
            `Quick
            test_network_read_preserves_exact_web_search_arguments
        ; Alcotest.test_case
            "unknown capability rejected"
            `Quick
            test_network_read_rejects_unknown_capability
        ; Alcotest.test_case
            "unknown envelope field rejected"
            `Quick
            test_network_read_rejects_unknown_envelope_fields
        ; Alcotest.test_case
            "applied result reaches current model turn"
            `Quick
            test_applied_replay_result_is_model_visible
        ; Alcotest.test_case
            "large result renders the standard blob marker"
            `Quick
            test_large_replay_result_reaches_model_exactly
        ; Alcotest.test_case
            "small result is inlined byte-exact"
            `Quick
            test_small_replay_result_is_inlined_exactly
        ] )
    ; ( "dispatch"
      , [ Alcotest.test_case
            "covers all replayable operations"
            `Quick
            test_dispatch_covers_all_replayable_operations
        ; Alcotest.test_case
            "refuses operations it cannot replay"
            `Quick
            test_dispatch_refuses_unknown_operations
        ; Alcotest.test_case
            "large connector request stays exact"
            `Quick
            test_large_connector_post_preserves_exact_durable_request
        ; Alcotest.test_case
            "connector decoder rejects heuristic input"
            `Quick
            test_connector_post_rejects_heuristic_or_truncated_input
        ] )
    ]
;;
