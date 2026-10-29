(** [Server_memory_recall_standing]: the recall gate per declared Keeper, as
    the server reads it, and the JSON of [GET /api/v1/runtime/config/memory-recall]. *)

open Masc
module S = Server_memory_recall_standing
module Standing = Keeper_memory_recall_standing

let environment_switch = "MASC_KEEPER_MEMORY_OS_RECALL"

let fresh_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Unix.realpath dir
;;

(* A keepers directory holding one declaration file per name. *)
let keepers_dir_with names =
  let dir = fresh_dir "masc_recall_standing" in
  List.iter
    (fun name ->
       Out_channel.with_open_text (Filename.concat dir (name ^ ".toml")) (fun channel ->
         output_string channel "# declaration\n"))
    names;
  dir
;;

let policy
      ?(enabled = true)
      ?(memory_recall = Runtime_schema.Memory_recall_off)
      ?(excluded_keepers = [])
      ()
  : Runtime_schema.typesafeai
  =
  { Runtime_schema.default_typesafeai with
    Runtime_schema.lane_enabled = enabled
  ; memory_recall
  ; excluded_keepers
  }
;;

let all = Runtime_schema.Memory_recall_on Runtime_schema.All_keepers

let listed first rest =
  Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers (first, rest))
;;

let with_key key f = Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" key f
let with_environment_switch value f = Masc_test_deps.with_process_env environment_switch value f
let with_policy p f = Masc_test_deps.with_typesafeai_policy p f

let read_exn ~keepers_dir =
  match S.read ~keepers_dir with
  | Ok standing -> standing
  | Error detail -> Alcotest.failf "the declarations could not be read: %s" detail
;;

let assoc_exn = function
  | `Assoc fields -> fields
  | _ -> Alcotest.fail "expected a JSON object"
;;

let string_exn = function
  | `String text -> text
  | _ -> Alcotest.fail "expected a JSON string"
;;

(* name -> standing word, in the order the response lists them. *)
let words_of standing =
  let json = S.to_yojson ~generated_at:"2026-10-29T00:00:00Z" standing in
  match List.assoc_opt "keepers" (assoc_exn json) with
  | Some (`List rows) ->
    List.map
      (fun row ->
         let fields = assoc_exn row in
         ( string_exn (List.assoc "name" fields)
         , string_exn (List.assoc "standing" fields) ))
      rows
  | _ -> Alcotest.fail "keepers is not a list"
;;

let lane_word standing =
  string_exn (List.assoc "lane" (assoc_exn (S.to_yojson ~generated_at:"" standing)))
;;

let keeper_word = Alcotest.(pair string string)

let test_each_keeper_gets_the_answer_of_a_turn () =
  let keepers_dir = keepers_dir_with [ "reader"; "other"; "stranger"; "silent" ] in
  with_environment_switch None (fun () ->
    with_key (Some "synthetic-jev-key") (fun () ->
      with_policy
        (policy ~memory_recall:(listed "reader" [ "other"; "silent" ]) ~excluded_keepers:[ "silent" ] ())
        (fun () ->
           let standing = read_exn ~keepers_dir in
           Alcotest.(check (list keeper_word))
             "in scope, outside the scope, excluded; sorted by name"
             [ "other", "judged"
             ; "reader", "judged"
             ; "silent", "keeper_excluded"
             ; "stranger", "memory_recall_disabled"
             ]
             (words_of standing);
           (* The report and a turn ask one function: they cannot differ. *)
           List.iter
             (fun (keeper : S.keeper) ->
                Alcotest.(check bool)
                  ("is_judged agrees for " ^ keeper.S.name)
                  (keeper.S.standing = Standing.Judged)
                  (Standing.is_judged ~keeper_id:keeper.S.name))
             standing.S.keepers)))
;;

let test_the_environment_switch_is_asked_before_the_gate () =
  let keepers_dir = keepers_dir_with [ "reader"; "stranger" ] in
  with_environment_switch (Some "false") (fun () ->
    with_key (Some "synthetic-jev-key") (fun () ->
      with_policy (policy ~memory_recall:(listed "reader" []) ()) (fun () ->
        Alcotest.(check (list keeper_word))
          "the switch closes recall for a Keeper the gate would judge, and names itself"
          [ "reader", "environment_switch_off"; "stranger", "environment_switch_off" ]
          (words_of (read_exn ~keepers_dir)))))
;;

let test_the_lane_is_told_whatever_the_recall_switch_says () =
  let keepers_dir = keepers_dir_with [ "reader" ] in
  with_environment_switch None (fun () ->
    with_key (Some "synthetic-jev-key") (fun () ->
      with_policy (policy ~memory_recall:Runtime_schema.Memory_recall_off ()) (fun () ->
        Alcotest.(check string) "armed with recall off" "armed" (lane_word (read_exn ~keepers_dir))));
    with_key None (fun () ->
      with_policy (policy ~memory_recall:Runtime_schema.Memory_recall_off ()) (fun () ->
        let standing = read_exn ~keepers_dir in
        Alcotest.(check string) "no key, recall off" "no_armed_destination" (lane_word standing);
        Alcotest.(check (list keeper_word))
          "a Keeper outside the scope says the switch, not the key"
          [ "reader", "memory_recall_disabled" ]
          (words_of standing));
      with_policy (policy ~memory_recall:all ()) (fun () ->
        Alcotest.(check (list keeper_word))
          "a Keeper in scope says the key"
          [ "reader", "no_armed_destination" ]
          (words_of (read_exn ~keepers_dir))));
    with_key (Some "synthetic-jev-key") (fun () ->
      with_policy (policy ~enabled:false ~memory_recall:all ()) (fun () ->
        let standing = read_exn ~keepers_dir in
        Alcotest.(check string) "lane switched off" "lane_disabled" (lane_word standing);
        Alcotest.(check (list keeper_word))
          "and the Keeper says so"
          [ "reader", "lane_disabled" ]
          (words_of standing))))
;;

let test_names_are_listed_once_and_sorted () =
  let keepers_dir = keepers_dir_with [ "b"; "a"; "c" ] in
  Out_channel.with_open_text (Filename.concat keepers_dir "notes.txt") (fun channel ->
    output_string channel "not a declaration\n");
  with_environment_switch None (fun () ->
    with_key (Some "synthetic-jev-key") (fun () ->
      with_policy (policy ~memory_recall:all ()) (fun () ->
        Alcotest.(check (list string))
          "only .toml declarations count"
          [ "a"; "b"; "c" ]
          (List.map fst (words_of (read_exn ~keepers_dir))))))
;;

(* The words are a wire contract: the TUI reads them back. *)
let test_the_words_are_distinct_and_read_back () =
  let words = List.map Standing.reason_to_string Standing.all_reasons in
  Alcotest.(check (list string))
    "the wire words"
    [ "environment_switch_off"
    ; "memory_recall_disabled"
    ; "keeper_excluded"
    ; "lane_disabled"
    ; "no_armed_destination"
    ]
    words;
  Alcotest.(check int)
    "no two reasons share a word"
    (List.length words)
    (List.length (List.sort_uniq String.compare words));
  List.iter
    (fun reason ->
       let word = Standing.reason_to_string reason in
       Alcotest.(check bool)
         ("reads back " ^ word)
         true
         (Standing.reason_of_string word = Some reason))
    Standing.all_reasons;
  List.iter
    (fun word ->
       Alcotest.(check bool)
         ("not a reason: " ^ word)
         true
         (Standing.reason_of_string word = None))
    [ Standing.judged_word; Standing.lane_armed_word; "absorb_gate_disabled"; "" ]
;;

(* The gate's own words stay the words of a reading, so a log line and the
   response name a refusal alike. *)
let test_a_refusal_of_the_gate_keeps_its_word () =
  List.iter
    (fun refusal ->
       Alcotest.(check string)
         "the word of the refusal"
         (Typesafeai_config.unavailable_reason_to_string refusal)
         (Standing.reason_to_string (Standing.reason_of_unavailable refusal)))
    [ Typesafeai_config.Memory_recall_disabled
    ; Typesafeai_config.Keeper_excluded
    ; Typesafeai_config.Lane_disabled
    ; Typesafeai_config.No_armed_destination
    ];
  List.iter
    (fun refusal ->
       Alcotest.(check bool)
         "the reason of another gate is not an answer of recall"
         true
         (Standing.reason_of_unavailable refusal = Standing.Recall_not_switched_on))
    [ Typesafeai_config.Absorb_gate_disabled
    ; Typesafeai_config.Board_attention_disabled
    ; Typesafeai_config.Context_review_disabled
    ; Typesafeai_config.Skill_applicability_disabled
    ; Typesafeai_config.Librarian_preflight_disabled
    ; Typesafeai_config.Workspace_memory_selection_disabled
    ]
;;

module Reading = Tui_decode_memory_recall

let decode_exn json =
  match Reading.decode_memory_recall_reading json with
  | Ok reading -> reading
  | Error detail -> Alcotest.failf "the TUI could not read the response: %s" detail
;;

let test_the_tui_reads_what_the_server_writes () =
  let keepers_dir = keepers_dir_with [ "reader"; "other"; "stranger"; "silent" ] in
  with_environment_switch None (fun () ->
    with_key (Some "synthetic-jev-key") (fun () ->
      with_policy
        (policy ~memory_recall:(listed "reader" [ "other"; "silent" ]) ~excluded_keepers:[ "silent" ] ())
        (fun () ->
           let standing = read_exn ~keepers_dir in
           let reading = decode_exn (S.to_yojson ~generated_at:"2026-10-29T00:00:00Z" standing) in
           Alcotest.(check bool) "the lane has a key" true (reading.Reading.mrr_lane = Ok ());
           Alcotest.(check bool)
             "every Keeper reads back as the server had it"
             true
             (reading.Reading.mrr_keepers
              = List.map (fun (keeper : S.keeper) -> keeper.S.name, keeper.S.standing) standing.S.keepers)));
    with_key None (fun () ->
      with_policy (policy ~memory_recall:all ()) (fun () ->
        let reading =
          decode_exn (S.to_yojson ~generated_at:"" (read_exn ~keepers_dir))
        in
        Alcotest.(check bool)
          "a lane without a key reads back as the reason"
          true
          (reading.Reading.mrr_lane = Error Standing.No_armed_destination))))
;;

let test_the_tui_refuses_what_it_does_not_know () =
  let keeper name standing = `Assoc [ "name", `String name; "standing", `String standing ] in
  let response ?(lane = `String "armed") ?(keepers = `List [ keeper "a" "judged" ]) () =
    `Assoc [ "lane", lane; "keepers", keepers ]
  in
  let refused label json =
    Alcotest.(check bool) label true (Result.is_error (Reading.decode_memory_recall_reading json))
  in
  Alcotest.(check bool)
    "the shape the tests below bend is read"
    true
    (Result.is_ok (Reading.decode_memory_recall_reading (response ())));
  refused "a lane word that is no reason" (response ~lane:(`String "judged") ());
  refused "a lane word that is nothing" (response ~lane:(`String "overheated") ());
  refused "a standing word that is nothing"
    (response ~keepers:(`List [ keeper "a" "quota_exceeded" ]) ());
  refused "armed is a word of the lane, not of a Keeper"
    (response ~keepers:(`List [ keeper "a" "armed" ]) ());
  refused "a Keeper listed twice"
    (response ~keepers:(`List [ keeper "a" "judged"; keeper "a" "keeper_excluded" ]) ());
  refused "a lane that is not a string" (response ~lane:(`Bool true) ());
  refused "keepers is not a list" (response ~keepers:(`String "a") ());
  refused "a Keeper without a name"
    (response ~keepers:(`List [ `Assoc [ "standing", `String "judged" ] ]) ());
  refused "no keepers field" (`Assoc [ "lane", `String "armed" ])
;;

let test_an_unreadable_directory_is_an_error_and_not_an_empty_list () =
  let missing = Filename.concat (fresh_dir "masc_recall_standing_missing") "keepers" in
  match S.read ~keepers_dir:missing with
  | Error _ -> ()
  | Ok standing ->
    Alcotest.failf
      "a directory that could not be read answered with %d Keepers"
      (List.length standing.S.keepers)
;;

let () =
  Alcotest.run
    "server_memory_recall_standing"
    [ ( "standing"
      , [ Alcotest.test_case "each Keeper gets the answer of a turn" `Quick
            test_each_keeper_gets_the_answer_of_a_turn
        ; Alcotest.test_case "the environment switch is asked before the gate" `Quick
            test_the_environment_switch_is_asked_before_the_gate
        ; Alcotest.test_case "the lane is told whatever the recall switch says" `Quick
            test_the_lane_is_told_whatever_the_recall_switch_says
        ; Alcotest.test_case "names are listed once and sorted" `Quick
            test_names_are_listed_once_and_sorted
        ; Alcotest.test_case "the words are distinct and read back" `Quick
            test_the_words_are_distinct_and_read_back
        ; Alcotest.test_case "a refusal of the gate keeps its word" `Quick
            test_a_refusal_of_the_gate_keeps_its_word
        ; Alcotest.test_case "the TUI reads what the server writes" `Quick
            test_the_tui_reads_what_the_server_writes
        ; Alcotest.test_case "the TUI refuses what it does not know" `Quick
            test_the_tui_refuses_what_it_does_not_know
        ; Alcotest.test_case "an unreadable directory is an error" `Quick
            test_an_unreadable_directory_is_an_error_and_not_an_empty_list
        ] )
    ]
;;
