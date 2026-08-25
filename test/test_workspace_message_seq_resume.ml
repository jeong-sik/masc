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
    ]
