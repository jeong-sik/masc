(* RFC-0356: the replayed write must carry the approved payload, not a
   payload the model re-emits. These cases pin the reconstruction from a
   stored Gate input to the write tool arguments. *)

(* The Gate replay/resolution wording lives in managed prompt templates
   under the config/prompts/keeper.gate_replay prefix. [Prompt_defaults.init]
   loads them, and the registry locates config/prompts itself under Dune;
   without a loaded registry the execution path falls back to bare data and
   the wording assertions below see nothing. *)
let () =
  Masc.Prompt_defaults.init ()
;;

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

let projected_model_text ~base_path
    (message : Masc.Keeper_gate_replay.model_message) =
  match message.replay_evidence with
  | None -> Alcotest.fail "model message has no replay evidence"
  | Some evidence ->
    (match
       Masc.Keeper_gate_replay.project_model_input
         ~base_path
         evidence
         [ Agent_core.Types.user_msg message.text ]
     with
     | Ok [ _canonical; projected ] ->
       Agent_core.Types.text_of_content projected.content
     | Ok _ -> Alcotest.fail "replay projection did not append exact evidence"
     | Error detail -> Alcotest.fail (Agent_core.Error.to_string detail))
;;

(* Reconstruction carries the approved payload fields back to the write
   handler. Capability identities remain inside the Gate effect and are not
   copied into the model-issued write arguments. *)
let approved_content_input =
  `Assoc
    [ ( "effect"
      , `Assoc [ "operation", `String "atomic_replace_entry" ] )
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
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let output = {|{"results":[{"title":"durable"}]}|} in
       let output_ref =
         match
           Masc.Keeper_gate_replay.For_testing.persist_replay_artifact
             ~base_path
             output
         with
         | Ok reference -> reference
         | Error detail -> Alcotest.fail detail
       in
       let message =
         Masc.Keeper_gate_replay.append_model_evidence
           ~approval_id:"approval-1"
           ~user_message:"continue"
           (Masc.Keeper_gate_replay.Applied
              { operation = "network_read"
              ; output_ref
              ; journal = Masc.Keeper_gate_replay.Replay_journal_recorded
              })
       in
       Alcotest.check
         Alcotest.bool
         "canonical history contains no full replay payload"
         false
         (String_util.contains_substring message.text "\"title\":\"durable\"");
       let evidence =
         projected_model_text ~base_path message
         |> String.split_on_char '\n'
         |> List.rev
         |> List.hd
         |> Yojson.Safe.from_string
       in
       (match
          evidence
          |> Yojson.Safe.Util.member "untrusted_tool_output_ref"
          |> Tool_output.normalized_artifact_ref_of_json
        with
        | Tool_output.Decoded_normalized_artifact_ref decoded ->
          Alcotest.check
            Alcotest.string
            "replay reference reaches the current provider turn"
            output_ref.sha256
            decoded.sha256
        | Tool_output.Not_normalized_artifact_ref ->
          Alcotest.fail "provider replay evidence lost its artifact reference"
        | Tool_output.Invalid_normalized_artifact_ref { detail } ->
          Alcotest.fail detail);
       Alcotest.check
         Alcotest.bool
         "current model turn cannot request the approved effect again"
         true
         (String_util.contains_substring
            message.text
            "Do not request the approved operation again"))
;;

let test_large_replay_result_stays_reference_only () =
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
       let message =
         Masc.Keeper_gate_replay.append_model_evidence
           ~approval_id:"approval-large"
           ~user_message:"continue"
           (Masc.Keeper_gate_replay.Applied
              { operation = "network_read"
              ; output_ref = artifact
              ; journal =
                  Masc.Keeper_gate_replay.Replay_journal_recorded
              })
       in
       Alcotest.check
         Alcotest.bool
         "canonical checkpoint does not retain the full replay tail"
         false
         (String_util.contains_substring message.text "LARGE-REPLAY-END");
       let canonical_evidence =
         message.text
         |> String.split_on_char '\n'
         |> List.rev
         |> List.find (fun line -> not (String.equal (String.trim line) ""))
         |> Yojson.Safe.from_string
       in
       (match
          canonical_evidence
          |> Yojson.Safe.Util.member "untrusted_tool_output_ref"
          |> Tool_output.normalized_artifact_ref_of_json
        with
        | Tool_output.Decoded_normalized_artifact_ref decoded ->
          Alcotest.check
            Alcotest.string
            "canonical replay reference keeps exact sha256"
            artifact.sha256
            decoded.sha256;
          Alcotest.check
            Alcotest.int
            "canonical replay reference keeps exact byte count"
            artifact.bytes
            decoded.bytes;
          Alcotest.check
            Alcotest.string
            "canonical replay reference carries no payload preview"
            ""
            decoded.preview
        | Tool_output.Not_normalized_artifact_ref ->
          Alcotest.fail "canonical replay evidence lost its typed artifact reference"
        | Tool_output.Invalid_normalized_artifact_ref { detail } ->
          Alcotest.failf "canonical replay artifact reference is invalid: %s" detail);
       let projected = projected_model_text ~base_path message in
       let projected_evidence =
         projected
         |> String.split_on_char '\n'
         |> List.rev
         |> List.find (fun line -> not (String.equal (String.trim line) ""))
         |> Yojson.Safe.from_string
       in
       (match
          projected_evidence
          |> Yojson.Safe.Util.member "untrusted_tool_output_ref"
          |> Tool_output.normalized_artifact_ref_of_json
        with
        | Tool_output.Decoded_normalized_artifact_ref decoded ->
          Alcotest.check
            Alcotest.string
            "provider projection keeps the exact artifact identity"
            artifact.sha256
            decoded.sha256
        | Tool_output.Not_normalized_artifact_ref ->
          Alcotest.fail "provider projection lost the replay reference"
        | Tool_output.Invalid_normalized_artifact_ref { detail } ->
          Alcotest.fail detail);
       Alcotest.check
         Alcotest.bool
         "provider projection does not hydrate the large replay payload"
         false
         (String_util.contains_substring projected "LARGE-REPLAY-END"))
;;

let test_multimodal_goal_projects_replay_reference () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let raw_output = "MULTIMODAL-REPLAY-EXACT" in
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
           ~approval_id:"approval-multimodal"
           ~user_message:"inspect the image"
           (Masc.Keeper_gate_replay.Applied
              { operation = "network_read"
              ; output_ref = artifact
              ; journal = Masc.Keeper_gate_replay.Replay_journal_recorded
              })
       in
       let evidence =
         match message.replay_evidence with
         | Some evidence -> evidence
         | None -> Alcotest.fail "multimodal replay evidence is absent"
       in
       let image =
         Agent_core.Types.Image
           { media_type = "image/png"
           ; data = "aW1hZ2U="
           ; source_type = Agent_core.Types.Base64
           }
       in
       let canonical_blocks =
         Masc.Keeper_gate_replay.append_model_evidence_block evidence [ image ]
       in
       let canonical_message =
         Agent_core.Types.user_msg_blocks canonical_blocks
       in
       Alcotest.check
         Alcotest.bool
         "multimodal canonical goal keeps only the artifact identity"
         false
         (String_util.contains_substring
            (Agent_core.Types.text_of_content canonical_message.content)
            raw_output);
       match
         Masc.Keeper_gate_replay.project_model_input
           ~base_path
           evidence
           [ canonical_message ]
       with
       | Error detail -> Alcotest.fail (Agent_core.Error.to_string detail)
       | Ok [ original; projected ] ->
         (match original.content, projected.content with
          | ( Agent_core.Types.Image _ :: Agent_core.Types.Text _ :: []
            , [ Agent_core.Types.Text evidence_text ] ) ->
            Alcotest.check
              Alcotest.bool
              "media block survives replay projection"
              true
              (not (String_util.contains_substring evidence_text raw_output))
          | _ ->
            Alcotest.fail
              "multimodal projection did not preserve canonical media and append replay evidence")
       | Ok _ -> Alcotest.fail "multimodal projection did not append one message")
;;

let test_replay_projection_recovers_when_canonical_reference_is_absent () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let artifact =
         match
           Masc.Keeper_gate_replay.For_testing.persist_replay_artifact
             ~base_path
             "available exact output"
         with
         | Ok artifact -> artifact
         | Error detail -> Alcotest.fail detail
       in
       let message =
         Masc.Keeper_gate_replay.append_model_evidence
           ~approval_id:"approval-missing-reference"
           ~user_message:"continue"
           (Masc.Keeper_gate_replay.Applied
              { operation = "network_read"
              ; output_ref = artifact
              ; journal = Masc.Keeper_gate_replay.Replay_journal_recorded
              })
       in
       let evidence =
         match message.replay_evidence with
         | Some evidence -> evidence
         | None -> Alcotest.fail "replay evidence is absent"
       in
       match
         Masc.Keeper_gate_replay.project_model_input
           ~base_path
           evidence
           [ Agent_core.Types.user_msg "reference was dropped" ]
       with
       | Error detail -> Alcotest.fail (Agent_core.Error.to_string detail)
       | Ok [ original; recovered ] ->
         Alcotest.check
           Alcotest.string
           "original provider input is preserved"
           "reference was dropped"
           (Agent_core.Types.text_of_content original.content);
         Alcotest.check
           Alcotest.bool
           "replay reference is appended independently of text layout"
           true
           (String_util.contains_substring
              (Agent_core.Types.text_of_content recovered.content)
              artifact.sha256)
       | Ok _ ->
         Alcotest.fail
           "replay recovery did not append one exact provider message")
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
    (replayable_of_operation "connector_post" = Some Replay_connector_post);
  Alcotest.check
    Alcotest.bool
    "memory_write is internal and never approval-replayed"
    true
    (replayable_of_operation "memory_write" = None);
  Alcotest.check
    Alcotest.bool
    "an approved identity_call is host-replayed"
    true
    (replayable_of_operation "identity_call" = Some Replay_identity)
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
    [ "masc_board_post"; "" ]
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
      ; "mention_user_ids", `List [ `String "U123ABC" ]
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
         ; thread_ts
         ; content = decoded_content
         ; blocks = decoded_blocks
         ; mention_user_ids
         }) ->
    Alcotest.check json "exact durable request retained" input decoded_input;
    Alcotest.check Alcotest.string "channel retained" "C-exact" channel_id;
    Alcotest.check
      (Alcotest.option Alcotest.string)
      "absent thread_ts stays absent"
      None
      thread_ts;
    Alcotest.check Alcotest.string "large content retained" content decoded_content;
    Alcotest.check
      (Alcotest.list json)
      "large blocks retained"
      blocks
      decoded_blocks;
    Alcotest.check (Alcotest.list Alcotest.string) "mention ids retained"
      [ "U123ABC" ] mention_user_ids
  | Ok (Replay_discord_post _) ->
    Alcotest.fail "Slack request decoded as Discord"
  | Error detail -> Alcotest.fail detail
;;

let test_slack_connector_post_retains_thread_ts () =
  let open Masc.Keeper_tool_in_process_runtime in
  let input =
    `Assoc
      [ "connector", `String "slack"
      ; "channel_id", `String "C-exact"
      ; "thread_ts", `String "1700000000.000100"
      ; "content", `String "threaded reply"
      ; "blocks", `List []
      ; "mention_user_ids", `List []
      ]
  in
  match
    Masc.Keeper_tool_in_process_runtime.connector_post_replay_of_gate_input
      input
  with
  | Ok (Replay_slack_post { thread_ts; channel_id; _ }) ->
    Alcotest.check Alcotest.string "channel retained" "C-exact" channel_id;
    Alcotest.check
      (Alcotest.option Alcotest.string)
      "thread coordinate retained"
      (Some "1700000000.000100")
      thread_ts
  | Ok (Replay_discord_post _) ->
    Alcotest.fail "Slack request decoded as Discord"
  | Error detail -> Alcotest.fail detail
;;

let test_connector_post_replay_retains_terminal_target () =
  let open Masc.Keeper_tool_in_process_runtime in
  let input =
    `Assoc
      [ "connector", `String "discord"
      ; "channel_id", `String "D-exact"
      ; "content", `String "approved reply"
      ; "mention_user_ids", `List []
      ]
  in
  match connector_post_replay_of_gate_input input with
  | Ok connector_post ->
    (match connector_post_replay_target connector_post with
     | Masc.Keeper_surface_post.To_discord { channel_id } ->
       Alcotest.check
         Alcotest.string
         "terminal target remains the approved channel"
         "D-exact"
         channel_id
     | ( Masc.Keeper_surface_post.To_dashboard
       | Masc.Keeper_surface_post.To_slack _ ) ->
       Alcotest.fail "Discord replay produced the wrong terminal target")
  | Error detail -> Alcotest.fail detail
;;

let test_connector_post_replay_requires_mention_user_ids () =
  let input =
    `Assoc
      [ "connector", `String "discord"
      ; "channel_id", `String "D-no-mentions-field"
      ; "content", `String "approved without the list"
      ]
  in
  match
    Masc.Keeper_tool_in_process_runtime.connector_post_replay_of_gate_input input
  with
  | Error detail ->
    Alcotest.check
      Alcotest.bool
      "names the missing field"
      true
      (String_util.contains_substring detail "missing mention_user_ids")
  | Ok _ -> Alcotest.fail "a request without mention_user_ids became replayable"
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
        ; "mention_user_ids", `List []
        ]
    ; `Assoc
        [ "connector", `String "discord"
        ; "channel_id", `String "D-exact"
        ; "content", `String "exact"
        ; "mention_user_ids", `List [ `String "123"; `String "123" ]
        ]
    ; `Assoc
        [ "connector", `String "discord"
        ; "channel_id", `String "D-exact"
        ; "content", `String "exact"
        ; "mention_user_ids", `List []
        ; "truncated", `Bool true
        ]
    ; `Assoc
        [ "connector", `String "slack"
        ; "channel_id", `String "C-exact"
        ; "thread_ts", `String "   "
        ; "content", `String "blank thread coordinate"
        ; "blocks", `List []
        ; "mention_user_ids", `List []
        ]
    ; `Assoc
        [ "connector", `String "slack"
        ; "channel_id", `String "C-exact"
        ; "thread_ts", `Int 1700000000
        ; "content", `String "non-string thread coordinate"
        ; "blocks", `List []
        ; "mention_user_ids", `List []
        ]
    ]
;;

(* The deferred payload is what the model reads when the Gate holds a call.
   Without the replay contract stated there, the model resubmits the same
   call while the approval is in flight (#28866: three duplicate approvals
   of one web_search). This pins the stated fact, not its wording. *)
let test_deferred_payload_states_the_replay_contract () =
  let payload =
    Masc.Keeper_gate.decision_to_yojson
      (Masc.Keeper_gate.Deferred
         { operation = Masc.Keeper_gate.network_read_gate_operation
         ; approval_id = "appr_test"
         ; reason = Masc.Keeper_gate.Judge_requested
         ; audit_receipts = []
         })
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "deferred decision"
    "deferred"
    (payload |> member "decision" |> to_string);
  let on_approve =
    match payload |> member "on_approve" with
    | `String text -> text
    | _ -> Alcotest.fail "deferred payload has no on_approve string"
  in
  Alcotest.(check bool)
    "on_approve states host replay delivery"
    true
    (Astring.String.is_infix ~affix:"delivers its output" on_approve);
  Alcotest.(check bool)
    "on_approve tells the model not to resubmit"
    true
    (Astring.String.is_infix ~affix:"Do not resubmit" on_approve)
;;

(* The mirror case: over an operation the replay engine does not recognize,
   the same wording promises a replay that never comes and starves the
   approved effect (#32668). The wording must instead hand the model the
   one-shot authorization it will actually receive. *)
let test_deferred_payload_promises_only_what_replay_spends () =
  let payload =
    Masc.Keeper_gate.decision_to_yojson
      (Masc.Keeper_gate.Deferred
         { operation = "unreplayed_operation"
         ; approval_id = "appr_unreplayed"
         ; reason = Masc.Keeper_gate.Judge_requested
         ; audit_receipts = []
         })
  in
  let open Yojson.Safe.Util in
  let on_approve =
    match payload |> member "on_approve" with
    | `String text -> text
    | _ -> Alcotest.fail "deferred payload has no on_approve string"
  in
  Alcotest.(check bool)
    "unrecognized operation is not promised a host replay"
    false
    (Astring.String.is_infix ~affix:"host replays this exact call" on_approve);
  Alcotest.(check bool)
    "unrecognized operation is told how to spend the approval"
    true
    (Astring.String.is_infix ~affix:"one-shot authorization" on_approve)
;;

(* Each producer states what its approval is about from its own typed decode
   of the stored Gate input. Nothing here searches the input for a field
   name: a field the model happens to call "command" belongs to whichever
   tool owns it, and only that tool's declared summary decides what the row
   says. The line comes back whole; the pane decides how much of it fits. *)
let summary = Alcotest.(option string)

let test_write_summary_is_the_target () =
  match
    Masc.Keeper_tool_filesystem_runtime.approved_write_of_gate_input
      approved_content_input
  with
  | Error detail -> Alcotest.fail detail
  | Ok write ->
    Alcotest.check
      summary
      "a write states the path it would write"
      (Some "/playground/executor/repos/masc/a.ml")
      (Masc.Keeper_tool_filesystem_runtime.write_call_summary
         ~requested_target:write.Masc.Keeper_tool_filesystem_runtime.target)
;;

let execute_summary input =
  match Masc.Keeper_tool_execute_runtime.replay_args_of_gate_input input with
  | Error detail -> Alcotest.fail detail
  | Ok args ->
    (match Masc.Keeper_tool_execute_typed_input.of_json args with
     | Error detail -> Alcotest.fail detail
     | Ok typed -> Masc.Keeper_tool_execute_input.typed_input_call_summary typed)
;;

let test_execute_summary_is_the_first_command_line () =
  Alcotest.check
    summary
    "argv joins onto one line"
    (Some "git status")
    (execute_summary approved_execute_input);
  let script text =
    `Assoc
      [ "schema", `String "masc.keeper_gate.request.v1"
      ; "input", `Assoc [ "script", `String text; "cwd", `String "/repo" ]
      ; "cwd", `String "/repo"
      ]
  in
  Alcotest.check
    summary
    "a script is named by its first command, blank lines skipped"
    (Some "cd repos/masc && git log --oneline -8 -- test/dune")
    (execute_summary
       (script "\n  cd repos/masc && git log --oneline -8 -- test/dune\n  dune build\n"));
  let long_line = "echo " ^ String.make 300 'a' in
  Alcotest.check
    summary
    "the line is not cut by the store"
    (Some long_line)
    (execute_summary (script (long_line ^ "\nsecond")))
;;

let test_network_read_summary_is_the_leaf_argument () =
  let open Masc.Keeper_tool_in_process_runtime in
  let stated input =
    match network_read_replay_of_gate_input input with
    | Ok replay -> network_read_call_summary replay
    | Error detail -> Alcotest.fail detail
  in
  Alcotest.check
    summary
    "web_search states its query"
    (Some "approved exact search")
    (stated approved_web_search_input);
  Alcotest.check
    summary
    "web_fetch states its url, not a field named command"
    (Some "https://example.com/page")
    (stated
       (`Assoc
         [ "capability", `String "web_fetch"
         ; ( "input"
           , `Assoc
               [ "url", `String "https://example.com/page"
               ; "command", `String "curl https://elsewhere.invalid"
               ] )
         ]));
  Alcotest.check
    summary
    "a fetch whose arguments name no url states nothing"
    None
    (network_read_call_summary
       (Replay_web_fetch (`Assoc [ "command", `String "curl x" ])))
;;

let test_connector_post_summary_names_where_and_what () =
  let open Masc.Keeper_tool_in_process_runtime in
  match
    connector_post_replay_of_gate_input
      (`Assoc
        [ "connector", `String "discord"
        ; "channel_id", `String "D-exact"
        ; "content", `String "first line\nsecond line"
        ; "mention_user_ids", `List []
        ])
  with
  | Error detail -> Alcotest.fail detail
  | Ok replay ->
    Alcotest.check
      summary
      "a post states its connector, channel and first line"
      (Some "discord D-exact: first line")
      (connector_post_call_summary replay)
;;

let test_identity_summary_is_the_provider_surface () =
  let input =
    Masc.Keeper_identity_gate.gate_input
      ~provider_id:"github"
      ~remote_name:"issue_write"
      ~arguments:
        (`Assoc [ "command", `String "rm -rf /"; "title", `String "a title" ])
  in
  match Masc.Keeper_identity_gate.replay_of_gate_input input with
  | Error detail -> Alcotest.fail detail
  | Ok call ->
    Alcotest.check
      summary
      "an identity call states provider/remote; its arguments are the remote's"
      (Some "github/issue_write")
      (Masc.Keeper_identity_gate.call_summary call)
;;

let test_speak_summary_is_the_first_line_of_the_message () =
  let open Masc.Keeper_tool_voice_runtime in
  (match
     speak_message_of_args
       (`Assoc [ "message", `String "  Hello team.\nSecond sentence." ])
   with
   | Error detail -> Alcotest.fail detail
   | Ok message ->
     Alcotest.check
       summary
       "a speak states the first line of what it would say"
       (Some "Hello team.")
       (speak_call_summary ~message));
  match speak_message_of_args (`Assoc [ "command", `String "say hello" ]) with
  | Ok message -> Alcotest.fail ("a speak without a message decoded: " ^ message)
  | Error _ -> ()
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
            "large result stays reference-only"
            `Quick
            test_large_replay_result_stays_reference_only
        ; Alcotest.test_case
            "multimodal goal projects replay reference"
            `Quick
            test_multimodal_goal_projects_replay_reference
        ; Alcotest.test_case
            "canonical reference layout does not control projection"
            `Quick
            test_replay_projection_recovers_when_canonical_reference_is_absent
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
        ; Alcotest.test_case
            "slack connector request retains thread_ts"
            `Quick
            test_slack_connector_post_retains_thread_ts
        ; Alcotest.test_case
            "connector replay retains terminal target"
            `Quick
            test_connector_post_replay_retains_terminal_target
        ; Alcotest.test_case
            "connector replay requires mention_user_ids"
            `Quick
            test_connector_post_replay_requires_mention_user_ids
        ; Alcotest.test_case
            "deferred payload states the replay contract"
            `Quick
            test_deferred_payload_states_the_replay_contract
        ; Alcotest.test_case
            "deferred payload promises only what replay spends"
            `Quick
            test_deferred_payload_promises_only_what_replay_spends
        ] )
    ; ( "declared call summaries"
      , [ Alcotest.test_case
            "a write states its target"
            `Quick
            test_write_summary_is_the_target
        ; Alcotest.test_case
            "an execute states its first command line, whole"
            `Quick
            test_execute_summary_is_the_first_command_line
        ; Alcotest.test_case
            "a network read states the leaf's own argument"
            `Quick
            test_network_read_summary_is_the_leaf_argument
        ; Alcotest.test_case
            "a connector post states where and what"
            `Quick
            test_connector_post_summary_names_where_and_what
        ; Alcotest.test_case
            "an identity call states its provider surface, not its arguments"
            `Quick
            test_identity_summary_is_the_provider_surface
        ; Alcotest.test_case
            "a speak states the first line of its message"
            `Quick
            test_speak_summary_is_the_first_line_of_the_message
        ] )
    ]
;;
