(* The replayed write must carry the approved payload, not a
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
  | [] | _ :: _ :: _ -> Alcotest.fail "model message requires one replay evidence"
  | [ evidence ] ->
    (match
       Masc.Keeper_gate_replay.project_model_input
         ~base_path
         evidence
         [ Agent_core.Types.user_msg message.text ]
     with
     | Ok [ _canonical; projected ] ->
       (match projected.content with
        | [Agent_core.Types.Text instruction; Agent_core.Types.Text marker] ->
          (match Tool_output.decode_from_agent_core marker with
           | Tool_output.Decoded _ -> instruction
           | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
             Alcotest.fail "canonical replay input lost its artifact owner")
        | _ -> Alcotest.fail "replay input must carry instruction and exact marker")
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

   The fixture is built by the producer itself rather than a hand-written
   copy of its shape: a hand-written fixture kept these cases green even if
   the producer stopped upserting the resolved [cwd] into the arguments
   (#26143), while live approvals then replayed nowhere. *)
let approved_execute_input =
  Masc.Keeper_tool_execute_runtime.execute_gate_input
    ~input:
      (`Assoc
         [ "argv", `List [ `String "git"; `String "status" ]
         ; "timeout_sec", `Int 30
         ])
    ~cwd:"/repo"
    ~sandbox_profile:"docker"
    ~sandbox_target:"docker:masc"
    ~network_mode:Keeper_types_profile_sandbox.Network_none
;;

let test_execute_args_are_the_approved_arguments () =
  Alcotest.check
    result_json
    "the approved arguments are replayed verbatim, with the approved cwd"
    (Ok
       (`Assoc
          [ "cwd", `String "/repo"
          ; "argv", `List [ `String "git"; `String "status" ]
          ; "timeout_sec", `Int 30
          ]))
    (Masc.Keeper_tool_execute_runtime.replay_args_of_gate_input
       approved_execute_input)
;;

(* Producer -> decoder round trip. The resolved [cwd] replaces whatever the
   model wrote, so replay carries the approved directory rather than the
   stale request. Re-submitting the replayed arguments under the same cwd and
   sandbox rebuilds the identical Gate input, which is what lets the
   canonical-input match spend the approval instead of failing it. *)
let test_execute_gate_input_round_trips () =
  let producer args =
    Masc.Keeper_tool_execute_runtime.execute_gate_input
      ~input:args
      ~cwd:"/approved"
      ~sandbox_profile:"docker"
      ~sandbox_target:"docker:masc"
    ~network_mode:Keeper_types_profile_sandbox.Network_none
  in
  let submitted =
    producer
      (`Assoc
         [ "argv", `List [ `String "ls" ]
         ; "cwd", `String "/requested-by-model"
         ])
  in
  match Masc.Keeper_tool_execute_runtime.replay_args_of_gate_input submitted with
  | Error detail -> Alcotest.fail detail
  | Ok replayed ->
    Alcotest.check
      json
      "replayed arguments name the resolved cwd, not the requested one"
      (`Assoc [ "cwd", `String "/approved"; "argv", `List [ `String "ls" ] ])
      replayed;
    Alcotest.check
      json
      "re-submitting the replayed arguments rebuilds the approved Gate input"
      submitted
      (producer replayed)
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
      [ "sandbox_profile"; "sandbox_target"; "network_mode"; "schema" ]
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
         |> List.find_opt (fun line ->
            not (String.equal (String.trim line) "")
            && not (Tool_output.is_marker line))
         |> (function
            | Some line -> line
            | None -> Alcotest.fail "no JSON line in the replay projection")
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
         |> List.find_opt (fun line ->
            not (String.equal (String.trim line) "")
            && not (Tool_output.is_marker line))
         |> (function
            | Some line -> line
            | None -> Alcotest.fail "no JSON line in the replay projection")
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
         | [ evidence ] -> evidence
         | [] | _ :: _ :: _ -> Alcotest.fail "multimodal replay evidence is not singular"
       in
       let image =
         Agent_core.Types.Image
           { media_type = "image/png"
           ; source = Agent_core.Types.Stored (Agent_core.History.stored_of_raw "image")
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
          | ( [ Agent_core.Types.Image _; Agent_core.Types.Text _; Agent_core.Types.Text _ ]
            , [ Agent_core.Types.Text evidence_text; Agent_core.Types.Text _ ] ) ->
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
         | [ evidence ] -> evidence
         | [] | _ :: _ :: _ -> Alcotest.fail "replay evidence is not singular"
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
    (replayable_of_operation "identity_call" = Some Replay_identity);
  Alcotest.check Alcotest.bool "an approved original media read is host-replayed" true
    (replayable_of_operation "media_read" = Some Replay_media_read)
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
  | Ok (Replay_native_post _ | Replay_discord_post _) ->
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
  | Ok (Replay_native_post _ | Replay_discord_post _) ->
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
     | ( Masc.Keeper_surface_post.To_native _
       | Masc.Keeper_surface_post.To_dashboard
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
  let command text =
    Masc.Keeper_tool_execute_runtime.execute_gate_input
      ~input:(`Assoc [ "command", `String text ])
      ~cwd:"/repo"
      ~sandbox_profile:"docker"
      ~sandbox_target:"docker:masc"
    ~network_mode:Keeper_types_profile_sandbox.Network_none
  in
  Alcotest.check
    summary
    "a multi-line command is named by its first line, blank lines skipped"
    (Some "cd repos/masc && git log --oneline -8 -- test/dune")
    (execute_summary
       (command "\n  cd repos/masc && git log --oneline -8 -- test/dune\n  dune build\n"));
  let long_line = "echo " ^ String.make 300 'a' in
  Alcotest.check
    summary
    "the line is not cut by the store"
    (Some long_line)
    (execute_summary (command (long_line ^ "\nsecond")))
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
    `Assoc
      [ "provider_id", `String "github"; "remote_name", `String "issue_write"
      ; "arguments", `Assoc [ "command", `String "rm -rf /"; "title", `String "a title" ]
      ; "input_schema", `Assoc [ "type", `String "object" ]; "read_only", `Bool false ]
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

(* #33373: an approval whose durable record is gone yields a plain model
   message, not replay evidence, and its log line names the store's answer. *)
let test_resolution_absent_tells_the_model_once () =
  let outcome =
    Masc.Keeper_gate_replay.Resolution_absent
      { absence = Masc.Keeper_approval_queue_result.Resolution_missing }
  in
  let message =
    Masc.Keeper_gate_replay.append_model_evidence
      ~approval_id:"approval-absent"
      ~user_message:"continue"
      outcome
  in
  Alcotest.(check bool)
    "names the approval"
    true
    (String_util.contains_substring message.text "approval-absent");
  Alcotest.(check bool)
    "names the store's answer"
    true
    (String_util.contains_substring message.text "resolution_missing");
  Alcotest.(check bool)
    "keeps the user message"
    true
    (String_util.contains_substring message.text "continue");
  Alcotest.(check bool)
    "carries no replay evidence"
    true
    (message.replay_evidence = []);
  Alcotest.(check string)
    "the log line names the store's answer"
    "resolution_absent store=resolution_missing"
    (Masc.Keeper_gate_replay.outcome_to_string outcome)
;;

module Media_replay_tests = struct
  open Masc
  module Original = Keeper_media_reading_original
  module Owner = Keeper_media_reading_owner
  module Generic = Lane_addon_tool_request_owner
  module Progress = Lane_addon_request_progress
  module Approval = Lane_addon_request_approval
  module Reply = Keeper_media_reading_reply
  module Queue = Keeper_approval_queue
  module Queue_result = Keeper_approval_queue_result
  module Gate = Keeper_gate
  module Replay = Keeper_gate_replay
  module Remote = Keeper_sandbox_remote
  module Sdk = Agent_core_protocol.Mcp_schema.Sdk_types

  let get show = function Ok value -> value | Error error -> Alcotest.fail (show error)
  let strings result = get Fun.id result
  let owned result = get Owner.error_to_string result
  let original result = get Original.error_to_string result
  let published = function
    | Owner.Stored value | Already_stored value -> value
    | Unconfirmed detail -> Alcotest.fail detail

  type fixture = {
    config : Workspace.config; meta : Keeper_meta_contract.keeper_meta;
    store : Lane_addon_store.t; owner : Original.owner; original : Original.t;
    request : Gate.request; approval_id : string; grant : Gate.cycle_grant;
  }

  let reload fixture =
    match owned (Owner.load ~store:fixture.store ~owner:fixture.owner
      ~request_id:(Original.request_id fixture.original)) with
    | Some value -> value | None -> Alcotest.fail "original disappeared"

  let advance fixture events =
    (match Generic.advance_events ~store:fixture.store
        ~expected:(Owner.record (reload fixture)) ~events with
     | Ok (Generic.Stored _ | Already_stored _) -> ()
     | Ok (Unconfirmed detail) -> Alcotest.fail detail
     | Error error -> Alcotest.fail (Generic.update_error_to_string error));
    reload fixture

  let resolution ~base_path ~keeper_name ~approval_id =
    let queue = strings (Keeper_registry_event_queue.snapshot_result ~base_path keeper_name) in
    let found = Keeper_event_queue.to_list queue |> List.find_map
      (fun (stimulus : Keeper_event_queue.stimulus) -> match stimulus.payload with
       | Keeper_event_queue.Hitl_resolved value ->
         if String.equal value.approval_id approval_id then Some value else None
       | Board_routing_pending _ | Board_signal _ | Board_attention _ | Bootstrap
       | Fusion_completed _ | Schedule_due _ | Connector_attention _ | Ask_answered _
       | Completion_authority_rejected _ | Task_cancelled _ | Workspace_message _
       | Delegate_completed _ | Composition_completed _ | Tool_result_ready _
       | Owned_job_completed _ | Task_outcome _ -> None) in
    match found with Some value -> value | None -> Alcotest.fail "actual approval wake missing"

  let with_fixture f =
    let base_path = Unix.realpath (temp_dir ()) in
    Queue.For_testing.reset_runtime_state ();
    Keeper_approval.Audit.For_testing.reset_store ();
    Fun.protect ~finally:(fun () ->
      Queue.For_testing.reset_runtime_state ();
      Keeper_approval.Audit.For_testing.reset_store ();
      cleanup_dir base_path) (fun () ->
      let config = Workspace.default_config base_path in
      let keeper_name = "media-replay-fixture" in
      let meta = strings (Masc_test_deps.meta_of_json_fixture
          (`Assoc ["name",`String keeper_name;"trace_id",`String "media-replay"])) in
      strings (Keeper_meta_store.replace_snapshot config meta);
      ignore (get Queue_result.install_error_to_string (Queue.install_persistence ~base_path));
      ignore (strings (Keeper_gate_mode.set config ~actor:"fixture" Keeper_gate_mode.Manual));
      let store = Lane_addon_store.create ~root:(Lane_addon_store.directory
          ~masc_dir:(Config_dir_resolver.masc_root ~base_path)) in
      let owner = original (Original.observe_owner ~base_path ~keeper_name) in
      let media = Agent_core.History.Memory_store.create () in
      let media_type = "application/pdf" in
      let stored = get Agent_core.History.show_media_error
          (media.put ~media_type ~raw:"retained fixture bytes, not a valid PDF") in
      let subject = original (Original.subject owner ~kind:Document ~media_type stored) in
      let source = original (Original.verify_source ~media_store:media subject) in
      let declaration : Runtime_schema.media_reader_decl =
        {id="recovery-only";revision="one";kind=Document;media_types=[media_type];
         adapter=Markitdown_mcp;command="must-not-run-reader";args=["--stdio"]} in
      (* Real Guest request preparation binds a recipe; no socket or program
         is opened by this recovery fixture. *)
      let endpoint = Remote.of_agent_socket ~base_path ~keeper_name ~remote_root:"/workspace"
          ~gh_config_dir:"/workspace/.config/gh" ~injected_env:[] ~env_allowlist:[]
          ~connect_timeout_sec:1 ~max_concurrent_sessions:1 ~container_name:"media-replay"
          ~shim_path:"/usr/local/bin/masc-exec-shim"
          ~host_socket:(Filename.concat base_path "never-connected.sock")
          ~expected:{Keeper_guest_socket.uid=Unix.getuid ();gid=Unix.getgid ()} in
      let argv = declaration.command :: declaration.args in
      let prepared = get (fun _ -> "Guest preparation refused")
          (Remote.Stdio_request.prepare ~timeout_sec:10. endpoint ~argv ~env:[||] ~cwd:None) in
      let launch = get (fun _ -> "Guest binding refused")
          (Remote.Stdio_request.binding prepared ~base_path ~keeper_name ~expected_argv:argv) in
      let channel = Keeper_continuation_channel.unrouted "media replay fixture" in
      let captured = original (Original.create ~execution_id:"media-replay-execution" ~source
          ~declaration ~launch ~causal_context:None ~task_id:None ~continuation_channel:channel) in
      let retained = owned (Owner.retain ~store captured) in
      let intent = strings (Keeper_media_reading_approval.intent captured) in
      let advance_record expected events =
        match Generic.advance_events ~store ~expected ~events with
        | Ok (Generic.Stored value | Already_stored value) -> value
        | Ok (Unconfirmed detail) -> Alcotest.fail detail
        | Error error -> Alcotest.fail (Generic.update_error_to_string error) in
      let intended = advance_record (Owner.record retained) [Progress.Approval_intended intent] in
      let request : Gate.request =
        {base_path;keeper_name;operation=Gate.media_read_gate_operation;
         input=Keeper_media_reading_approval.input captured;call_summary=None;
         causal_context=None;task_id=None;continuation_channel=Some channel;sandbox_profile=None} in
      let approval_id = match Gate.decide ~intent:Keeper_tool_execute_typed_input.Request_effect
          ~keeper_always_allow:false request with
        | Gate.Deferred value -> value.approval_id
        | Allow _ -> Alcotest.fail "manual media approval bypassed"
        | Unavailable reason -> Alcotest.fail (Gate.unavailable_reason_to_string reason) in
      let wait = strings (Approval.wait intent ~approval_id
          ~input_hash:(Keeper_approval_request_fingerprint.input_hash (Approval.request intent))) in
      ignore (advance_record intended [Progress.Approval_wait_retained wait]);
      ignore (get Queue.resolve_error_to_string (Queue.resolve_with_policy ~base_path ~id:approval_id
          ~decision:Keeper_approval_queue_rules_types.Decision.Approve
          ~source:Keeper_approval_queue_rules_types.Human_operator ()));
      let grant = match Gate.cycle_grant_of_resolution (resolution ~base_path ~keeper_name ~approval_id) with
        | Some grant -> grant | None -> Alcotest.fail "actual approved wake has no grant" in
      f {config;meta;store;owner;original=captured;request;approval_id;grant})

  let consume ?grant fixture =
    let grant = Option.value grant ~default:fixture.grant in
    match Gate.decide ~intent:Keeper_tool_execute_typed_input.Request_effect
        ~cycle_grant:grant ~keeper_always_allow:false fixture.request with
    | Gate.Allow authorization ->
      Alcotest.(check bool) "actual resume spends the exact original approval" true
        (authorization.source = Gate.One_shot_resolution fixture.approval_id)
    | Deferred _ | Unavailable _ -> Alcotest.fail "approved original did not resume"

  let run ?media_replayer fixture =
    let publication_recovery = {Keeper_publication_recovery_availability.provider=
        Keeper_publication_recovery_availability.non_runtime_provider;
        keeper_name=fixture.meta.name} in
    match media_replayer with
    | None -> Replay.replay_approved_effect_with_receipt
        ~config:fixture.config ~meta:fixture.meta ~publication_recovery
        ~turn_sandbox_factory:None ~grant:fixture.grant ~approval_id:fixture.approval_id ()
    | Some media_replayer -> Replay.For_testing.replay_media_with_receipt ~media_replayer
        ~config:fixture.config ~meta:fixture.meta ~publication_recovery
        ~turn_sandbox_factory:None ~grant:fixture.grant ~approval_id:fixture.approval_id ()

  let delivery fixture = get Queue_result.grant_error_to_string
      (Queue.approved_resolution_delivery ~base_path:fixture.config.base_path ~id:fixture.approval_id)

  let retain_answer ?grant fixture =
    consume ?grant fixture;
    let pending = advance fixture [Progress.Dispatch_intended] in
    let sdk : Sdk.tool_result =
      {content=[TextContent {type_="text";text="retained media answer";annotations=None}];
       is_error=Some false;structured_content=None;
       _meta=Some (`Assoc ["private",`String "SDK-only-private-value"])} in
    let reply = strings (Reply.capture_sdk_reply sdk) in
    let retained = owned (Owner.retain_reply ~store:fixture.store ~expected:pending ~reply) |> published in
    let retained = owned (Owner.retain_transport ~store:fixture.store ~expected:retained
      ~observation:(Remote.Execution_unavailable (Remote.Transport_unavailable Remote.Acceptance_read))) |> published in
    let reply_ref = match strings (Reply.validate_progress ~original:fixture.original (Owner.record retained).progress) with
      | Some link -> Reply.artifact link | None -> Alcotest.fail "reply link missing" in
    let transport_ref = match Owner.transport_artifact retained with
      | Some value -> value | None -> Alcotest.fail "transport link missing" in
    retained, reply_ref, transport_ref

  let recovered_reply () = with_fixture (fun fixture ->
    let before, reply_ref, transport_ref = retain_answer fixture in
    let result = run fixture in
    let public_ref = match result.outcome with
      | Replay.Applied {output_ref;_} -> output_ref
      | Not_applicable | Applied_with_warning _ | Failed _ | Indeterminate _
      | Repair_required _ | Resolution_absent _ -> Alcotest.fail "retained reading was not recovered" in
    Alcotest.(check bool) "reading invents no terminal effect receipt" true
      (Option.is_none result.terminal_effect_receipt);
    let evidence = match (delivery fixture).replay_outcome with
      | Some (Queue_result.Replay_applied evidence) -> evidence
      | Some (Replay_applied_with_warning _ | Replay_failed _ | Replay_indeterminate _) | None ->
        Alcotest.fail "actual replay sidecar did not retain recovered reading" in
    List.iter (fun (reference : Tool_output.artifact_ref) ->
      Alcotest.(check bool) "private artifact survives Gate settlement" true
        (List.exists (fun (root : Tool_output.artifact_ref) -> root.sha256=reference.sha256)
          evidence.retained_artifacts)) [reply_ref;transport_ref];
    Alcotest.(check bool) "private SDK blob is never the public model artifact" false
      (public_ref.sha256=reply_ref.sha256);
    let public_bytes = match get Tool_blob_store.fetch_error_to_string
        (Tool_blob_store.fetch (Tool_blob_store.create ~base_path:fixture.config.base_path) ~sha256:public_ref.sha256) with
      | Some bytes -> bytes | None -> Alcotest.fail "public replay artifact missing" in
    Alcotest.(check bool) "private SDK metadata is not copied into replay text" false
      (String_util.contains_substring public_bytes "SDK-only-private-value");
    ignore (run fixture);
    Alcotest.(check bool) "repeated settlement preserves the original's exact progress" true
      (Generic.same_record (Owner.record before) (Owner.record (reload fixture))))

  let consumed_without_reply () = with_fixture (fun fixture ->
    consume fixture;
    let before = advance fixture [Progress.Dispatch_intended] in
    ignore (strings (Keeper_gate_mode.set fixture.config ~actor:"fixture" Keeper_gate_mode.Always_allow));
    (match (run fixture).outcome with
     | Replay.Indeterminate _ -> ()
     | Not_applicable | Applied _ | Applied_with_warning _ | Failed _
     | Repair_required _ | Resolution_absent _ -> Alcotest.fail "spent grant without reply did not remain unknown");
    Alcotest.(check bool) "changed Allow policy cannot dispatch the spent original" true
      (Generic.same_record (Owner.record before) (Owner.record (reload fixture)));
    Alcotest.(check bool) "recovery invents no answer" true
      (owned (Owner.load_reply ~store:fixture.store before) = None))

  let missing_linked_reply () = with_fixture (fun fixture ->
    let before, reply_ref, _ = retain_answer fixture in
    let root = Tool_blob_store.root_dir (Tool_blob_store.create ~base_path:fixture.config.base_path) in
    Unix.unlink (Filename.concat (Filename.concat root (String.sub reply_ref.sha256 0 2)) reply_ref.sha256);
    (match (run fixture).outcome with
     | Replay.Repair_required {stage;_} ->
       Alcotest.(check bool) "linked blob damage is an evidence repair" true (stage=Replay.Evidence_retrieval)
     | Not_applicable | Applied _ | Applied_with_warning _ | Failed _ | Indeterminate _
     | Resolution_absent _ -> Alcotest.fail "linked missing reply became a fresh execution or terminal result");
    Alcotest.(check bool) "repair does not manufacture a replay outcome" true
      (Option.is_none (delivery fixture).replay_outcome);
    Alcotest.(check bool) "repair preserves the original and damaged link" true
      (Generic.same_record (Owner.record before) (Owner.record (reload fixture))))

  type interrupted_publication = Lost_ack | Raised_after_reply | Cancelled_after_reply

  let interrupted_reply failure () = with_fixture (fun fixture ->
    let invocations = ref 0 in
    let produce ~grant ~approval_id ~input =
      incr invocations;
      Alcotest.(check string) "media branch forwards its actual approval ID"
        fixture.approval_id approval_id;
      Alcotest.check json "media branch forwards complete approved input" fixture.request.input input;
      ignore (retain_answer ~grant fixture);
      match failure with
      | Lost_ack -> Error (Keeper_media_reading.Progress_unconfirmed "fixture lost ACK after real reply publication")
      | Raised_after_reply -> failwith "fixture callback raised after real reply publication"
      | Cancelled_after_reply ->
        raise (Eio.Cancel.Cancelled (Failure "fixture cancellation after real reply publication")) in
    let replay () = run ~media_replayer:produce fixture in
      (match replay () with
       | result ->
         (match failure with
          | Cancelled_after_reply -> Alcotest.fail "media replay swallowed cancellation"
          | Lost_ack | Raised_after_reply ->
            match result.outcome with
            | Replay.Repair_required _ -> ()
            | Not_applicable | Applied _ | Applied_with_warning _ | Failed _
            | Indeterminate _ | Resolution_absent _ -> Alcotest.fail "partial publication became terminal")
       | exception Eio.Cancel.Cancelled _ ->
         (match failure with
          | Cancelled_after_reply -> ()
          | Lost_ack | Raised_after_reply -> Alcotest.fail "non-cancellation changed into cancellation"));
      Alcotest.(check bool) "uncertain result does not close the Gate recovery path" true
        (Option.is_none (delivery fixture).replay_outcome);
      Alcotest.(check bool) "actual original reply remains readable" true
        (Option.is_some (owned (Owner.load_reply ~store:fixture.store (reload fixture))));
      (match (replay ()).outcome with
       | Replay.Applied _ -> ()
       | Not_applicable | Applied_with_warning _ | Failed _ | Indeterminate _
       | Repair_required _ | Resolution_absent _ -> Alcotest.fail "next wake did not recover the retained reply");
      Alcotest.(check int) "recovery never calls the invocation port again" 1 !invocations)

  let tests = Alcotest.[
    test_case "actual grant and consumed reply recover private roots" `Quick recovered_reply;
    test_case "consumed without reply ignores changed Allow policy" `Quick consumed_without_reply;
    test_case "missing linked reply stays repair-required" `Quick missing_linked_reply;
    test_case "lost reply acknowledgement leaves consumed recovery open" `Quick (interrupted_reply Lost_ack);
    test_case "exception after reply leaves consumed recovery open" `Quick (interrupted_reply Raised_after_reply);
    test_case "cancellation after reply propagates and recovery stays open" `Quick (interrupted_reply Cancelled_after_reply)]
end

let () =
  Alcotest.run
    "keeper_gate_replay"
    [ ("media original replay", Media_replay_tests.tests)
    ; ( "filesystem producer replay decoder"
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
            "producer round trip keeps the resolved cwd"
            `Quick
            test_execute_gate_input_round_trips
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
    ; ( "absent resolution"
      , [ Alcotest.test_case
            "tells the model the approval has no record and carries no evidence"
            `Quick
            test_resolution_absent_tells_the_model_once
        ] )
    ]
;;
