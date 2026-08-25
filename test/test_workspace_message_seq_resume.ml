(** The message counter is recovered from the store, not restarted at zero.

    Message files are the authority on what has been said; the counter in
    workspace state only says where to continue. Rebuilding that state beside
    a store that already holds messages used to restart the counter, and every
    message written afterwards took a number below the ones already filed. A
    reader paging in sequence order never reaches them, however far back it
    asks — [select_recent_message_names] compares sequences, so a lower number
    is always older to it.

    On 2026-08-25 that happened on the live workspace: state was rebuilt at
    04:38:42Z with 2,604 messages on disk, and the following eight and a half
    hours of broadcasts landed at sequences 1-75. Keepers asked each other for
    help there and the requests were unreadable. Seven numbers were issued
    twice. *)

open Alcotest

module Paths = Workspace_utils_paths_backend
module Bootstrap = Workspace_bootstrap
module Setup = Workspace_utils_backend_setup

let with_workspace f =
  let base = Filename.temp_dir "wsseq" "" in
  let messages = Filename.concat (Filename.concat base ".masc") "messages" in
  let rec mkdir_p dir =
    if not (Sys.file_exists dir) then begin
      mkdir_p (Filename.dirname dir);
      try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  mkdir_p messages;
  f (Setup.default_config base) messages

let file_a_message dir seq =
  let name =
    Printf.sprintf "%09d_keeper-alpha-agent_wmsg-%d_broadcast.json" seq seq
  in
  let out = open_out (Filename.concat dir name) in
  output_string out "{}";
  close_out out

let test_a_name_yields_its_sequence () =
  check int "padded" 75
    (Paths.message_seq_of_filename
       "000000075_keeper-alpha-agent_wmsg-abc_broadcast.json");
  check int "unpadded, as older files were written" 1664
    (Paths.message_seq_of_filename "1664_keeper-alpha-agent_broadcast.json")

let test_a_name_that_is_not_ours_yields_none () =
  check int "no sequence" 0
    (Paths.message_seq_of_filename "notes_keeper-alpha_broadcast.json");
  check int "empty leader" 0 (Paths.message_seq_of_filename "_alpha.json");
  check int "no separator" 0 (Paths.message_seq_of_filename "000000075.json");
  (* Zero is what a name without a sequence answers, so a file numbered zero
     cannot be told from one, and neither may lift the counter. *)
  check int "zero itself" 0
    (Paths.message_seq_of_filename "000000000_alpha_wmsg-x_broadcast.json")

let test_an_empty_store_starts_at_zero () =
  with_workspace (fun config _messages ->
    check int "nothing said yet" 0
      (Bootstrap.default_workspace_state config).message_seq)

let test_a_missing_store_starts_at_zero () =
  let base = Filename.temp_dir "wsseq_bare" "" in
  check int "no messages directory" 0
    (Bootstrap.default_workspace_state (Setup.default_config base)).message_seq

(* The regression itself: state rebuilt beside a store that already holds
   messages. Before this fix the answer was 0 and the next broadcast was
   filed below everything already there. *)
let test_a_rebuilt_state_resumes_above_the_store () =
  with_workspace (fun config messages ->
    List.iter (file_a_message messages) [ 1; 2; 2603; 2604 ];
    check int "continues after the highest filed" 2604
      (Bootstrap.default_workspace_state config).message_seq)

let test_the_highest_wins_whatever_the_order_on_disk () =
  with_workspace (fun config messages ->
    List.iter (file_a_message messages) [ 2604; 7; 1200 ];
    check int "not the first read, not the last" 2604
      (Bootstrap.default_workspace_state config).message_seq)

let test_a_stray_file_does_not_lift_the_counter () =
  with_workspace (fun config messages ->
    List.iter (file_a_message messages) [ 12 ];
    let out = open_out (Filename.concat messages "README.md") in
    output_string out "not a message";
    close_out out;
    check int "only ours counts" 12
      (Bootstrap.default_workspace_state config).message_seq)

(* Boot reconciliation: a workspace that already reset does not pass through
   [default_workspace_state] again, so raising the counter has to happen where
   the store and the counter are both at rest. Without this a reset workspace
   stays broken until someone edits state.json, which is what 2026-08-25
   required. *)

(* State goes through the workspace's own reader and writer. A test that
   touched the file directly would pass or fail on which storage backend the
   run happened to pick, and this one picks Memory when there is no Eio fs
   context. Message files stay on disk because [resume_message_seq] reads the
   directory itself. *)
let state_path config = Paths.state_path config

let write_state_with config seq =
  Workspace_utils_ops.write_json config (state_path config)
    (`Assoc
      [ "protocol_version", `String "0.1.0"
      ; "project", `String "p"
      ; "started_at", `String "t"
      ; "message_seq", `Int seq
      ; "active_agents", `List []
      ]);
  state_path config

let recorded_seq config path =
  match Workspace_utils_ops.read_json config path with
  | `Assoc fields -> (
      match List.assoc_opt "message_seq" fields with
      | Some (`Int seq) -> seq
      | Some _ | None -> -1)
  | _ -> -1

let test_boot_lifts_a_counter_that_fell_behind () =
  with_workspace (fun config messages ->
    List.iter (file_a_message messages) [ 1; 84; 2604 ];
    let path = write_state_with config 84 in
    Bootstrap.ensure_workspace_bootstrap config;
    check int "raised to the store" 2604 (recorded_seq config path))

let test_boot_leaves_a_counter_that_is_ahead () =
  with_workspace (fun config messages ->
    List.iter (file_a_message messages) [ 12 ];
    let path = write_state_with config 900 in
    Bootstrap.ensure_workspace_bootstrap config;
    check int "untouched" 900 (recorded_seq config path))

let test_boot_leaves_a_counter_that_matches () =
  with_workspace (fun config messages ->
    List.iter (file_a_message messages) [ 2604 ];
    let path = write_state_with config 2604 in
    Bootstrap.ensure_workspace_bootstrap config;
    check int "untouched" 2604 (recorded_seq config path))

let test_boot_leaves_the_counter_when_nothing_is_filed () =
  with_workspace (fun config _messages ->
    let path = write_state_with config 7 in
    Bootstrap.ensure_workspace_bootstrap config;
    check int "an empty store says nothing about the counter" 7
      (recorded_seq config path))

(* Unreadable state belongs to [read_state], which has the typed recovery.
   Rewriting it here would throw away whatever that recovery could still
   salvage from the file. *)
let test_boot_does_not_touch_unreadable_state () =
  with_workspace (fun config messages ->
    List.iter (file_a_message messages) [ 2604 ];
    let path = state_path config in
    Workspace_utils_ops.write_json config path (`String "not a state object");
    Bootstrap.ensure_workspace_bootstrap config;
    check string "left for the typed recovery" {|"not a state object"|}
      (Yojson.Safe.to_string (Workspace_utils_ops.read_json config path)))

let () =
  run "workspace message seq resume"
    [ ( "filename"
      , [ test_case "a name yields its sequence" `Quick
            test_a_name_yields_its_sequence
        ; test_case "a name that is not ours yields none" `Quick
            test_a_name_that_is_not_ours_yields_none
        ] )
    ; ( "resume"
      , [ test_case "an empty store starts at zero" `Quick
            test_an_empty_store_starts_at_zero
        ; test_case "a missing store starts at zero" `Quick
            test_a_missing_store_starts_at_zero
        ; test_case "a rebuilt state resumes above the store" `Quick
            test_a_rebuilt_state_resumes_above_the_store
        ; test_case "the highest wins whatever the order on disk" `Quick
            test_the_highest_wins_whatever_the_order_on_disk
        ; test_case "a stray file does not lift the counter" `Quick
            test_a_stray_file_does_not_lift_the_counter
        ] )
    ; ( "boot"
      , [ test_case "boot lifts a counter that fell behind" `Quick
            test_boot_lifts_a_counter_that_fell_behind
        ; test_case "boot leaves a counter that is ahead" `Quick
            test_boot_leaves_a_counter_that_is_ahead
        ; test_case "boot leaves a counter that matches" `Quick
            test_boot_leaves_a_counter_that_matches
        ; test_case "boot leaves the counter when nothing is filed" `Quick
            test_boot_leaves_the_counter_when_nothing_is_filed
        ; test_case "boot does not touch unreadable state" `Quick
            test_boot_does_not_touch_unreadable_state
        ] )
    ]
