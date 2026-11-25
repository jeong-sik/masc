(* The fixture is the session journal muse acp 1.4.25 wrote for two prompts.
   Each prompt called one MCP tool, so each run holds two model requests and
   one approval review, and the host was restarted between them. Rows of the
   kinds the reader never decodes were thinned out: those that held this
   machine's paths or were large are gone, and at most two of each other kind
   remain. The rows the reader counts are untouched.

   The observers' fixtures come from other real muse acp 1.4.25 journals: a
   parent journal that linked two observers, the journals of those two
   children, and the journal of a child that was cancelled during its model
   request. They keep only the rows the reader decodes, with their values. Two
   fields are replaced because the reader never reads them: the [prompt] text
   of every started row and the plugin name in the link rows. *)

open Alcotest
module Log = Runtime_muse_session_log

let fixture_lines =
  In_channel.with_open_bin "fixtures/muse/muse-acp-1.4.25-two-runs.jsonl" In_channel.input_all
  |> String.split_on_char '\n'
  |> List.filter (fun line -> line <> "")
  |> Array.of_list
;;

(* Line numbers in the fixture, counted from 0. *)
let last_line = Array.length fixture_lines - 1
let first_line_of_prompt_1 = 18
let run_1_started = 21
let run_1_terminal = 58
let host_restart_line = 62
let last_line_before_run_2 = 65
let run_2_started = 66
let run_2_first_request = 68
let run_2_review = 72
let run_2_terminal = 79
let run_2_id = "01a2113f-6a1e-7b42-aff9-e0c65a1d9363"
let session_id = "01a2113e-b6c0-7f71-bab2-c29018711194"

let lines ~first ~last = Array.to_list (Array.sub fixture_lines first (last - first + 1))
let text_of lines = String.concat "" (List.map (fun line -> line ^ "\n") lines)
let text ~first ~last = text_of (lines ~first ~last)

let rec set_in json keys value =
  match keys, json with
  | [], _ -> value
  | key :: rest, `Assoc fields ->
    if List.mem_assoc key fields
    then
      `Assoc
        (List.map
           (fun (name, v) -> if name = key then (name, set_in v rest value) else (name, v))
           fields)
    else failwith ("the fixture line has no field " ^ key)
  | _ :: _, _ -> failwith "the fixture line is not an object"
;;

let set_field line keys value =
  Yojson.Safe.to_string (set_in (Yojson.Safe.from_string line) keys value)
;;

let rec remove_in json keys =
  match keys, json with
  | [ key ], `Assoc fields when List.mem_assoc key fields ->
    `Assoc (List.remove_assoc key fields)
  | key :: (_ :: _ as rest), `Assoc fields when List.mem_assoc key fields ->
    `Assoc
      (List.map
         (fun (name, v) -> if name = key then (name, remove_in v rest) else (name, v))
         fields)
  | _ -> failwith "the fixture line has no such field"
;;

let without_field line keys =
  Yojson.Safe.to_string (remove_in (Yojson.Safe.from_string line) keys)
;;

let edited index keys value = set_field fixture_lines.(index) keys value

let lines_with_edits ~first ~last edits =
  List.mapi
    (fun position line ->
       match List.assoc_opt (first + position) edits with
       | Some line -> line
       | None -> line)
    (lines ~first ~last)
;;

(* ── A sessions directory in a temporary data home ───────────────────────── *)

let rec remove_tree path =
  if Sys.is_directory path
  then (
    Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path
;;

let with_data_home f =
  let data_home = Filename.temp_dir "muse-session-log-" "" in
  Fun.protect ~finally:(fun () -> remove_tree data_home) (fun () -> f data_home)
;;

let rec make_directories path =
  if not (Sys.file_exists path)
  then (
    make_directories (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let journal_path data_home ~day ~id =
  List.fold_left Filename.concat data_home [ "muse"; "sessions"; day; id; "session.jsonl" ]
;;

let write_file path contents =
  make_directories (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc contents)
;;

let append_file path contents =
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o644 path (fun oc ->
    Out_channel.output_string oc contents)
;;

let root_of data_home =
  match Log.root_of_environment [| "XDG_DATA_HOME=" ^ data_home |] with
  | Ok root -> root
  | Error err -> failf "root_of_environment: %s" (Log.error_to_string err)
;;

let mark_ok root ~id =
  match Log.mark root ~session_id:id with
  | Ok mark -> mark
  | Error err -> failf "mark: %s" (Log.error_to_string err)
;;

let read_ok mark =
  match Log.read_turn mark with
  | Ok turn -> turn
  | Error err -> failf "read_turn: %s" (Log.error_to_string err)
;;

let describe = function
  | Ok (_ : Log.turn) -> "a turn"
  | Error err -> Log.error_to_string err
;;

let error_t =
  testable (fun ppf err -> Format.pp_print_string ppf (Log.error_to_string err)) ( = )
;;

let turn_t =
  testable
    (fun ppf (turn : Log.turn) ->
       Format.fprintf
         ppf
         "main in=%d out=%d cache_read=%d reasoning=%d write=%d requests=%d last_in=%s | \
          review in=%d out=%d cache_read=%d reasoning=%d calls=%d | \
          observers in=%d out=%d cache_read=%d reasoning=%d finished=%d running=%d \
          without_journal=%d"
         turn.main.input_tokens
         turn.main.output_tokens
         turn.main.cache_read_tokens
         turn.main.reasoning_tokens
         turn.main_cache_write_tokens
         turn.main_requests
         (match turn.last_request_input_tokens with
          | Some n -> string_of_int n
          | None -> "none")
         turn.review.input_tokens
         turn.review.output_tokens
         turn.review.cache_read_tokens
         turn.review.reasoning_tokens
         turn.reviews
         turn.observers.counts.input_tokens
         turn.observers.counts.output_tokens
         turn.observers.counts.cache_read_tokens
         turn.observers.counts.reasoning_tokens
         turn.observers.finished
         turn.observers.running
         turn.observers.without_journal)
    ( = )
;;

(* ── What the fixture's records add up to ────────────────────────────────── *)

let counts ~input ~output ~cache_read ~reasoning =
  { Log.input_tokens = input
  ; output_tokens = output
  ; cache_read_tokens = cache_read
  ; reasoning_tokens = reasoning
  }
;;

let nothing = counts ~input:0 ~output:0 ~cache_read:0 ~reasoning:0
let no_observers = { Log.counts = nothing; finished = 0; running = 0; without_journal = 0 }

(* Run 1: requests of 23241 in / 134 out / 0 cache read / 64 reasoning and
   23429 / 36 / 23156 / 19, and a review of 12628 / 244 / 0 / 112. *)
let prompt_1 =
  { Log.main = counts ~input:46670 ~output:170 ~cache_read:23156 ~reasoning:83
  ; main_cache_write_tokens = 0
  ; main_requests = 2
  ; last_request_input_tokens = Some 23429
  ; review = counts ~input:12628 ~output:244 ~cache_read:0 ~reasoning:112
  ; reviews = 1
  ; observers = no_observers
  }
;;

(* Run 2: requests of 23527 / 74 / 23412 / 4 and 23654 / 20 / 23412 / 4, and a
   review of 15424 / 205 / 0 / 82. *)
let prompt_2 =
  { Log.main = counts ~input:47181 ~output:94 ~cache_read:46824 ~reasoning:8
  ; main_cache_write_tokens = 0
  ; main_requests = 2
  ; last_request_input_tokens = Some 23654
  ; review = counts ~input:15424 ~output:205 ~cache_read:0 ~reasoning:82
  ; reviews = 1
  ; observers = no_observers
  }
;;

let both_prompts =
  { Log.main = counts ~input:93851 ~output:264 ~cache_read:69980 ~reasoning:91
  ; main_cache_write_tokens = 0
  ; main_requests = 4
  ; last_request_input_tokens = Some 23654
  ; review = counts ~input:28052 ~output:449 ~cache_read:0 ~reasoning:194
  ; reviews = 2
  ; observers = no_observers
  }
;;

(* A journal that holds everything before prompt 2, marked there. *)
let journal_before_run_2 data_home =
  let path = journal_path data_home ~day:"2026/11/25" ~id:session_id in
  write_file path (text ~first:0 ~last:last_line_before_run_2);
  path, mark_ok (root_of data_home) ~id:session_id
;;

(* ── The observers' fixtures ─────────────────────────────────────────────── *)

let read_fixture name =
  In_channel.with_open_bin ("fixtures/muse/" ^ name) In_channel.input_all
  |> String.split_on_char '\n'
  |> List.filter (fun line -> line <> "")
;;

(* The parent's rows: the run starts, links child A, makes a request, links
   child B, makes a request and ends. *)
let observers_parent = Array.of_list (read_fixture "muse-acp-1.4.25-observers-parent.jsonl")
let parent_link_a = 1
let parent_link_b = 3
let parent_terminal = 5
let observers_session_id = "01a211de-1163-7231-9757-91df0a810ebc"
let child_a_path = "subagent/01a211de-34dd-7062-98d9-80dd6b9928fc/session.jsonl"
let child_a_run_id = "01a211de-34dd-7062-98d9-80dd6b9928fc"
let child_b_path = "subagent/01a211de-4365-7e70-8699-00517bccba9b/session.jsonl"
let child_cancelled_path = "subagent/01a211cd-091d-7ab0-934a-55d5f98c7705/session.jsonl"

(* Each child's journal: a started row, its one request (not for the cancelled
   child) and a terminal row. *)
let child_a = read_fixture "muse-acp-1.4.25-observer-child-completed-a.jsonl"
let child_b = read_fixture "muse-acp-1.4.25-observer-child-completed-b.jsonl"
let child_cancelled = read_fixture "muse-acp-1.4.25-observer-child-cancelled.jsonl"

(* The parent's two requests: 23941 / 138 / 23793 / 29 and 24763 / 269 / 23921 /
   248. Child A's request is 1981 / 255 / 1521 / 197 and child B's 2754 / 199 /
   1777 / 141. *)
let child_a_counts = counts ~input:1981 ~output:255 ~cache_read:1521 ~reasoning:197
let both_children_counts = counts ~input:4735 ~output:454 ~cache_read:3298 ~reasoning:338

let observers_of ~observer_counts ~finished ~running ~without_journal =
  { Log.counts = observer_counts; finished; running; without_journal }
;;

let both_children_finished =
  observers_of
    ~observer_counts:both_children_counts
    ~finished:2
    ~running:0
    ~without_journal:0
;;

let observers_prompt observers =
  { Log.main = counts ~input:48704 ~output:407 ~cache_read:47714 ~reasoning:277
  ; main_cache_write_tokens = 0
  ; main_requests = 2
  ; last_request_input_tokens = Some 24763
  ; review = nothing
  ; reviews = 0
  ; observers
  }
;;

(* The parent's rows, with the rows of [edits] replaced and the [extra] rows
   put before the terminal row. *)
let parent_rows ?(edits = []) ?(extra = []) () =
  List.concat
    (List.mapi
       (fun index line ->
          let line = Option.value (List.assoc_opt index edits) ~default:line in
          if index = parent_terminal then extra @ [ line ] else [ line ])
       (Array.to_list observers_parent))
;;

let observers_session_directory data_home =
  Filename.dirname (journal_path data_home ~day:"2026/11/25" ~id:observers_session_id)
;;

(* Marks the parent's empty journal, writes the children's own journals, then
   adds the rows of the prompt. *)
let send_observers_prompt data_home ~parent ~children =
  let path = journal_path data_home ~day:"2026/11/25" ~id:observers_session_id in
  write_file path "";
  let mark = mark_ok (root_of data_home) ~id:observers_session_id in
  List.iter
    (fun (relative, rows) ->
       write_file
         (Filename.concat (observers_session_directory data_home) relative)
         (text_of rows))
    children;
  append_file path (text_of parent);
  mark
;;

(* ── Tests ───────────────────────────────────────────────────────────────── *)

let test_root_of_environment () =
  let root env = Result.map Log.root_directory (Log.root_of_environment env) in
  let check_root name expected env =
    check (result string error_t) name expected (root env)
  in
  check_root
    "an absolute XDG_DATA_HOME wins"
    (Ok "/x/muse/sessions")
    [| "HOME=/h"; "XDG_DATA_HOME=/x" |];
  check_root "HOME when XDG_DATA_HOME is unset" (Ok "/h/.local/share/muse/sessions") [| "HOME=/h" |];
  check_root
    "an empty XDG_DATA_HOME is unset"
    (Ok "/h/.local/share/muse/sessions")
    [| "HOME=/h"; "XDG_DATA_HOME=" |];
  check_root
    "a relative XDG_DATA_HOME is unset"
    (Ok "/h/.local/share/muse/sessions")
    [| "HOME=/h"; "XDG_DATA_HOME=data" |];
  check_root
    "a variable with a longer name is not XDG_DATA_HOME"
    (Ok "/h/.local/share/muse/sessions")
    [| "HOME=/h"; "XDG_DATA_HOME_OLD=/x" |];
  check_root "a relative HOME is no directory" (Error Log.Data_root_unavailable) [| "HOME=h" |];
  check_root "an empty environment" (Error Log.Data_root_unavailable) [||]
;;

let test_sums_each_prompt_of_the_captured_journal () =
  with_data_home (fun data_home ->
    let path = journal_path data_home ~day:"2026/11/25" ~id:session_id in
    write_file path (text ~first:0 ~last:(first_line_of_prompt_1 - 1));
    let root = root_of data_home in
    let mark_1 = mark_ok root ~id:session_id in
    append_file path (text ~first:first_line_of_prompt_1 ~last:run_1_terminal);
    check turn_t "prompt 1" prompt_1 (read_ok mark_1);
    let mark_2 = mark_ok root ~id:session_id in
    append_file path (text ~first:(run_1_terminal + 1) ~last:last_line);
    check turn_t "prompt 2" prompt_2 (read_ok mark_2);
    check turn_t "both prompts from the first mark" both_prompts (read_ok mark_1))
;;

let test_reads_a_journal_that_was_empty_at_the_mark () =
  with_data_home (fun data_home ->
    let path = journal_path data_home ~day:"2026/11/25" ~id:session_id in
    write_file path "";
    let mark = mark_ok (root_of data_home) ~id:session_id in
    append_file path (text ~first:first_line_of_prompt_1 ~last:run_1_terminal);
    check turn_t "prompt 1" prompt_1 (read_ok mark))
;;

let test_skips_a_record_half_written_at_the_mark () =
  with_data_home (fun data_home ->
    let path = journal_path data_home ~day:"2026/11/25" ~id:session_id in
    let record = fixture_lines.(host_restart_line) in
    let half = String.length record / 2 in
    write_file
      path
      (text ~first:0 ~last:(host_restart_line - 1) ^ String.sub record 0 half);
    let mark = mark_ok (root_of data_home) ~id:session_id in
    append_file
      path
      (String.sub record half (String.length record - half)
       ^ "\n"
       ^ text ~first:(host_restart_line + 1) ~last:last_line);
    check turn_t "prompt 2" prompt_2 (read_ok mark))
;;

let test_leaves_out_a_record_still_being_written () =
  with_data_home (fun data_home ->
    let path, mark = journal_before_run_2 data_home in
    let terminal = fixture_lines.(run_2_terminal) in
    let half = String.length terminal / 2 in
    append_file
      path
      (text ~first:run_2_started ~last:(run_2_terminal - 1) ^ String.sub terminal 0 half);
    check
      (result turn_t error_t)
      "the terminal record has no newline yet"
      (Error (Log.Run_not_terminated { run_id = run_2_id }))
      (Log.read_turn mark);
    append_file path (String.sub terminal half (String.length terminal - half) ^ "\n");
    check turn_t "prompt 2 once the record is complete" prompt_2 (read_ok mark))
;;

let test_counts_a_run_that_made_no_request () =
  with_data_home (fun data_home ->
    let path = journal_path data_home ~day:"2026/11/25" ~id:session_id in
    write_file path (text ~first:0 ~last:(first_line_of_prompt_1 - 1));
    let mark = mark_ok (root_of data_home) ~id:session_id in
    append_file path (text_of [ fixture_lines.(run_1_started); fixture_lines.(run_1_terminal) ]);
    check
      turn_t
      "no request, no review"
      { Log.main = nothing
      ; main_cache_write_tokens = 0
      ; main_requests = 0
      ; last_request_input_tokens = None
      ; review = nothing
      ; reviews = 0
      ; observers = no_observers
      }
      (read_ok mark))
;;

let test_a_run_that_started_before_the_mark_is_not_the_prompts () =
  with_data_home (fun data_home ->
    let path = journal_path data_home ~day:"2026/11/25" ~id:session_id in
    write_file path (text ~first:0 ~last:run_1_started);
    let mark = mark_ok (root_of data_home) ~id:session_id in
    append_file path (text ~first:(run_1_started + 1) ~last:run_1_terminal);
    check
      (result turn_t error_t)
      "the slice holds the requests and the terminal record but no started record"
      (Error Log.No_run_in_slice)
      (Log.read_turn mark))
;;

let test_ignores_the_records_of_a_run_the_prompt_did_not_start () =
  with_data_home (fun data_home ->
    let path, mark = journal_before_run_2 data_home in
    (* A request of run 1 that reaches the journal after the mark, such as the
       tail of a cancelled prompt, ahead of run 2's own records. *)
    append_file
      path
      (text_of [ fixture_lines.(56) ]
       ^ text ~first:run_2_started ~last:run_2_terminal);
    check turn_t "only run 2 is counted" prompt_2 (read_ok mark))
;;

let test_reports_a_prompt_that_added_no_run () =
  with_data_home (fun data_home ->
    let path, mark = journal_before_run_2 data_home in
    append_file path (text ~first:last_line ~last:last_line);
    check
      (result turn_t error_t)
      "only a session_end record was added"
      (Error Log.No_run_in_slice)
      (Log.read_turn mark))
;;

let test_refuses_a_schema_it_was_not_checked_against () =
  with_data_home (fun data_home ->
    let path, mark = journal_before_run_2 data_home in
    let review = edited run_2_review [ "payload_schema_version" ] (`Int 4) in
    append_file
      path
      (text_of
         (lines_with_edits ~first:run_2_started ~last:run_2_terminal [ run_2_review, review ]));
    check
      (result turn_t error_t)
      "an approval payload at version 4"
      (Error
         (Log.Unsupported_schema
            { record = "approval/automated_review_completed"; found = 4; supported = 3 }))
      (Log.read_turn mark));
  with_data_home (fun data_home ->
    let path, mark = journal_before_run_2 data_home in
    let request = edited run_2_first_request [ "schema_version" ] (`Int 2) in
    append_file
      path
      (text_of
         (lines_with_edits
            ~first:run_2_started
            ~last:run_2_terminal
            [ run_2_first_request, request ]));
    check
      (result turn_t error_t)
      "an envelope at version 2"
      (Error
         (Log.Unsupported_schema
            { record = "run/model_completed envelope"; found = 2; supported = 1 }))
      (Log.read_turn mark))
;;

let test_rejects_counts_that_contradict_the_accounting () =
  with_data_home (fun data_home ->
    let path, mark = journal_before_run_2 data_home in
    let request =
      edited
        run_2_first_request
        [ "payload"; "event"; "usage"; "cache_read_tokens" ]
        (`Int 99_999_999)
    in
    append_file
      path
      (text_of
         (lines_with_edits
            ~first:run_2_started
            ~last:run_2_terminal
            [ run_2_first_request, request ]));
    match Log.read_turn mark with
    | Error (Log.Malformed_record { byte_offset; _ }) ->
      check
        int
        "the offset of the edited record"
        (String.length (text ~first:0 ~last:(run_2_first_request - 1)))
        byte_offset
    | other -> failf "expected a malformed record, got %s" (describe other))
;;

let test_rejects_a_line_that_is_not_json () =
  with_data_home (fun data_home ->
    let path, mark = journal_before_run_2 data_home in
    append_file path ("not json\n" ^ text ~first:run_2_started ~last:run_2_terminal);
    match Log.read_turn mark with
    | Error (Log.Malformed_record { byte_offset; _ }) ->
      check
        int
        "the line starts where the prompt began"
        (String.length (text ~first:0 ~last:last_line_before_run_2))
        byte_offset
    | other -> failf "expected a malformed record, got %s" (describe other))
;;

let test_finds_a_session_that_began_on_an_earlier_day () =
  with_data_home (fun data_home ->
    let older = journal_path data_home ~day:"2026/10/03" ~id:session_id in
    write_file older (text ~first:0 ~last:(first_line_of_prompt_1 - 1));
    List.iter
      (fun (day, id) -> write_file (journal_path data_home ~day ~id) "another session\n")
      [ "2026/11/25", "0aaa0000-another-session"; "2026/11/30", "0bbb0000-another-session" ];
    let mark = mark_ok (root_of data_home) ~id:session_id in
    append_file older (text ~first:first_line_of_prompt_1 ~last:run_1_terminal);
    check turn_t "prompt 1" prompt_1 (read_ok mark))
;;

let test_reports_a_missing_journal_and_unusable_ids () =
  with_data_home (fun data_home ->
    let root = root_of data_home in
    check
      (result unit error_t)
      "no such session"
      (Error
         (Log.Session_log_not_found
            { searched = Log.root_directory root; session_id = "no-such-session" }))
      (Result.map ignore (Log.mark root ~session_id:"no-such-session"));
    List.iter
      (fun id ->
         check
           (result unit error_t)
           (Printf.sprintf "id %S" id)
           (Error (Log.Session_id_invalid id))
           (Result.map ignore (Log.mark root ~session_id:id)))
      [ ""; "."; ".."; "a/b"; "../x"; "a\\b" ])
;;

let test_reports_a_journal_that_shrank () =
  with_data_home (fun data_home ->
    let path, mark = journal_before_run_2 data_home in
    let shorter = text ~first:0 ~last:10 in
    write_file path shorter;
    check
      (result turn_t error_t)
      "the file was rewritten shorter"
      (Error
         (Log.Journal_shrank
            { path
            ; marked_at = String.length (text ~first:0 ~last:last_line_before_run_2)
            ; size = String.length shorter
            }))
      (Log.read_turn mark))
;;

let test_adds_the_observers_a_prompt_linked () =
  with_data_home (fun data_home ->
    (* A third child that the host cancelled during its model request. *)
    let link_cancelled =
      set_field
        observers_parent.(parent_link_a)
        [ "payload"; "event"; "child_session_log_path" ]
        (`String child_cancelled_path)
    in
    let mark =
      send_observers_prompt
        data_home
        ~parent:(parent_rows ~extra:[ link_cancelled ] ())
        ~children:
          [ child_a_path, child_a
          ; child_b_path, child_b
          ; child_cancelled_path, child_cancelled
          ]
    in
    let turn = read_ok mark in
    check
      turn_t
      "the two requests of the children, none for the cancelled one"
      (observers_prompt
         (observers_of
            ~observer_counts:both_children_counts
            ~finished:3
            ~running:0
            ~without_journal:0))
      turn;
    check int "total input" (48704 + 4735) (Log.total turn).Log.input_tokens;
    check int "total output" (407 + 454) (Log.total turn).Log.output_tokens)
;;

let test_leaves_out_an_observer_that_is_still_running () =
  with_data_home (fun data_home ->
    let without_terminal = List.filteri (fun index _ -> index < 2) child_b in
    let mark =
      send_observers_prompt
        data_home
        ~parent:(parent_rows ())
        ~children:[ child_a_path, child_a; child_b_path, without_terminal ]
    in
    check
      turn_t
      "child B has a request but no terminal record"
      (observers_prompt
         (observers_of
            ~observer_counts:child_a_counts
            ~finished:1
            ~running:1
            ~without_journal:0))
      (read_ok mark);
    append_file
      (Filename.concat (observers_session_directory data_home) child_b_path)
      (text_of [ List.nth child_b 2 ]);
    check
      turn_t
      "child B once its terminal record is written"
      (observers_prompt both_children_finished)
      (read_ok mark))
;;

let test_reports_an_observer_linked_without_a_journal () =
  with_data_home (fun data_home ->
    let link_b =
      without_field
        observers_parent.(parent_link_b)
        [ "payload"; "event"; "child_session_log_path" ]
    in
    let mark =
      send_observers_prompt
        data_home
        ~parent:(parent_rows ~edits:[ parent_link_b, link_b ] ())
        ~children:[ child_a_path, child_a ]
    in
    check
      turn_t
      "child B has no journal to read"
      (observers_prompt
         (observers_of
            ~observer_counts:child_a_counts
            ~finished:1
            ~running:0
            ~without_journal:1))
      (read_ok mark))
;;

let test_refuses_a_journal_path_outside_the_session_directory () =
  List.iter
    (fun path ->
       with_data_home (fun data_home ->
         let link =
           set_field
             observers_parent.(parent_link_a)
             [ "payload"; "event"; "child_session_log_path" ]
             (`String path)
         in
         let rows = parent_rows ~edits:[ parent_link_a, link ] () in
         let mark = send_observers_prompt data_home ~parent:rows ~children:[] in
         match Log.read_turn mark with
         | Error (Log.Malformed_record { byte_offset; _ }) ->
           check
             int
             (Printf.sprintf "the offset of the link row for path %S" path)
             (String.length (text_of (List.filteri (fun index _ -> index < parent_link_a) rows)))
             byte_offset
         | other -> failf "path %S: expected a malformed record, got %s" path (describe other)))
    [ ""; "/etc/session.jsonl"; "../session.jsonl"; "subagent/../../session.jsonl" ]
;;

let test_names_the_journal_of_an_observer_it_cannot_read () =
  with_data_home (fun data_home ->
    let request = set_field (List.nth child_a 1) [ "payload_schema_version" ] (`Int 2) in
    let mark =
      send_observers_prompt
        data_home
        ~parent:(parent_rows ())
        ~children:
          [ child_a_path, [ List.nth child_a 0; request; List.nth child_a 2 ]
          ; child_b_path, child_b
          ]
    in
    check
      (result turn_t error_t)
      "a request of child A at payload version 2"
      (Error
         (Log.Observer_journal
            { path = Filename.concat (observers_session_directory data_home) child_a_path
            ; cause =
                Log.Unsupported_schema
                  { record = "run/model_completed"; found = 2; supported = 1 }
            }))
      (Log.read_turn mark));
  with_data_home (fun data_home ->
    let mark =
      send_observers_prompt
        data_home
        ~parent:(parent_rows ())
        ~children:[ child_a_path, child_a ]
    in
    match Log.read_turn mark with
    | Error (Log.Observer_journal { path; cause = Log.Read_failed _ }) ->
      check
        string
        "the journal of child B, which was not written"
        (Filename.concat (observers_session_directory data_home) child_b_path)
        path
    | other -> failf "expected an unreadable observer journal, got %s" (describe other))
;;

let test_refuses_an_observer_that_links_observers_of_its_own () =
  with_data_home (fun data_home ->
    (* A link row of child A's own run, before child A's terminal row. *)
    let nested =
      set_field
        (set_field
           observers_parent.(parent_link_a)
           [ "payload"; "run_id" ]
           (`String child_a_run_id))
        [ "payload"; "event"; "parent_run_id" ]
        (`String child_a_run_id)
    in
    let mark =
      send_observers_prompt
        data_home
        ~parent:(parent_rows ())
        ~children:
          [ ( child_a_path
            , [ List.nth child_a 0; List.nth child_a 1; nested; List.nth child_a 2 ] )
          ; child_b_path, child_b
          ]
    in
    check
      (result turn_t error_t)
      "child A links a child of its own"
      (Error
         (Log.Observer_journal
            { path = Filename.concat (observers_session_directory data_home) child_a_path
            ; cause = Log.Nested_observers
            }))
      (Log.read_turn mark))
;;

let test_ignores_the_observers_of_a_run_the_prompt_did_not_start () =
  with_data_home (fun data_home ->
    (* A link of an earlier run that reaches the journal after the mark, ahead
       of the prompt's own rows. The child it names is not there, and is not
       looked for. *)
    let earlier_run = "01a211de-0000-7000-8000-000000000000" in
    let late_link =
      List.fold_left
        (fun line (keys, value) -> set_field line keys (`String value))
        observers_parent.(parent_link_a)
        [ [ "payload"; "run_id" ], earlier_run
        ; [ "payload"; "event"; "parent_run_id" ], earlier_run
        ; [ "payload"; "event"; "child_session_log_path" ], "subagent/not-written/session.jsonl"
        ]
    in
    let mark =
      send_observers_prompt
        data_home
        ~parent:(late_link :: parent_rows ())
        ~children:[ child_a_path, child_a; child_b_path, child_b ]
    in
    check
      turn_t
      "only the observers of the prompt's own run"
      (observers_prompt both_children_finished)
      (read_ok mark))
;;

let () =
  run
    "runtime_muse_session_log"
    [ ( "journal"
      , [ test_case "data root from the host's environment" `Quick test_root_of_environment
        ; test_case
            "sums each prompt of a captured journal"
            `Quick
            test_sums_each_prompt_of_the_captured_journal
        ; test_case
            "reads a journal that was empty at the mark"
            `Quick
            test_reads_a_journal_that_was_empty_at_the_mark
        ; test_case
            "skips a record half written at the mark"
            `Quick
            test_skips_a_record_half_written_at_the_mark
        ; test_case
            "leaves out a record still being written"
            `Quick
            test_leaves_out_a_record_still_being_written
        ; test_case
            "counts a run that made no request"
            `Quick
            test_counts_a_run_that_made_no_request
        ; test_case
            "a run that started before the mark is not the prompt's"
            `Quick
            test_a_run_that_started_before_the_mark_is_not_the_prompts
        ; test_case
            "ignores the records of a run the prompt did not start"
            `Quick
            test_ignores_the_records_of_a_run_the_prompt_did_not_start
        ; test_case
            "reports a prompt that added no run"
            `Quick
            test_reports_a_prompt_that_added_no_run
        ; test_case
            "refuses a schema it was not checked against"
            `Quick
            test_refuses_a_schema_it_was_not_checked_against
        ; test_case
            "rejects counts that contradict the accounting"
            `Quick
            test_rejects_counts_that_contradict_the_accounting
        ; test_case
            "rejects a line that is not json"
            `Quick
            test_rejects_a_line_that_is_not_json
        ; test_case
            "finds a session that began on an earlier day"
            `Quick
            test_finds_a_session_that_began_on_an_earlier_day
        ; test_case
            "reports a missing journal and unusable ids"
            `Quick
            test_reports_a_missing_journal_and_unusable_ids
        ; test_case
            "reports a journal that shrank"
            `Quick
            test_reports_a_journal_that_shrank
        ] )
    ; ( "observers"
      , [ test_case
            "adds the observers a prompt linked"
            `Quick
            test_adds_the_observers_a_prompt_linked
        ; test_case
            "leaves out an observer that is still running"
            `Quick
            test_leaves_out_an_observer_that_is_still_running
        ; test_case
            "reports an observer linked without a journal"
            `Quick
            test_reports_an_observer_linked_without_a_journal
        ; test_case
            "refuses a journal path outside the session directory"
            `Quick
            test_refuses_a_journal_path_outside_the_session_directory
        ; test_case
            "names the journal of an observer it cannot read"
            `Quick
            test_names_the_journal_of_an_observer_it_cannot_read
        ; test_case
            "refuses an observer that links observers of its own"
            `Quick
            test_refuses_an_observer_that_links_observers_of_its_own
        ; test_case
            "ignores the observers of a run the prompt did not start"
            `Quick
            test_ignores_the_observers_of_a_run_the_prompt_did_not_start
        ] )
    ]
;;
