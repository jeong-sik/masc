(** F-3: Aggregate personality_field_empty WARN emission.

    Pre-fix: each missing personality field ({will,needs,desires}) emitted its
    own [Log.Keeper.warn] line.  At 3 empty fields × 134 build cycles / 24h
    that produced ~666 WARN entries.

    Post-fix: [build_keeper_system_prompt] emits a single WARN per build
    that lists every missing field.  Per-field Prometheus counters and the
    in-prompt config-drift markers stay identical so dashboards and the
    LLM-visible drift signal are unchanged. *)

open Alcotest

module KP = Masc_mcp.Keeper_prompt

(* Per-build snapshot of Keeper WARN entries emitted by build_keeper_system_prompt.
   Filters on the canonical aggregation prefix written by F-3. *)
let aggregated_warn_lines ~before_seq () =
  let entries =
    Masc_log.Ring.recent ?since_seq:before_seq
      ~module_filter:"Keeper" ~order:`Oldest_first ()
  in
  List.filter_map
    (fun (entry : Masc_log.Ring.entry) ->
      match entry.level with
      | Masc_log.Warn ->
          if
            String.length entry.message >= 1
            && (try
                  ignore
                    (Str.search_forward
                       (Str.regexp_string "personality fields empty:")
                       entry.message 0);
                  true
                with Not_found -> false)
          then Some entry.message
          else None
      | _ -> None)
    entries

let latest_seq () =
  match Masc_log.Ring.recent ~limit:1 () with
  | [] -> None
  | entry :: _ -> Some entry.seq

let build_with ~will ~needs ~desires =
  let _ : string =
    KP.build_keeper_system_prompt
      ~goal:"verify personality WARN aggregation"
      ~short_goal:"single-emit WARN"
      ~mid_goal:"reduce WARN volume 3:1"
      ~long_goal:"keep operator dashboards quiet"
      ~will ~needs ~desires
      ~instructions:""
      ()
  in
  ()

let test_all_three_fields_empty_emits_single_warn_with_all_names () =
  let before_seq = latest_seq () in
  build_with ~will:"" ~needs:"" ~desires:"";
  let warns = aggregated_warn_lines ~before_seq () in
  check int "exactly one aggregated WARN" 1 (List.length warns);
  let msg = List.hd warns in
  let has needle =
    try
      ignore (Str.search_forward (Str.regexp_string needle) msg 0);
      true
    with Not_found -> false
  in
  check bool "WARN message names will" true (has "will");
  check bool "WARN message names needs" true (has "needs");
  check bool "WARN message names desires" true (has "desires");
  check bool "field list rendered as bracketed enumeration" true
    (has "[will, needs, desires]")

let test_single_field_empty_emits_single_warn_with_one_name () =
  let before_seq = latest_seq () in
  build_with ~will:"" ~needs:"keeps grounding" ~desires:"observable progress";
  let warns = aggregated_warn_lines ~before_seq () in
  check int "exactly one aggregated WARN" 1 (List.length warns);
  let msg = List.hd warns in
  let has needle =
    try
      ignore (Str.search_forward (Str.regexp_string needle) msg 0);
      true
    with Not_found -> false
  in
  check bool "WARN names the empty field" true (has "will");
  check bool "WARN does not name a populated field (needs)" false
    (has "needs");
  check bool "WARN does not name a populated field (desires)" false
    (has "desires")

let test_no_empty_fields_emits_no_warn () =
  let before_seq = latest_seq () in
  build_with ~will:"maintain coherent identity"
    ~needs:"factual grounding" ~desires:"useful progress";
  let warns = aggregated_warn_lines ~before_seq () in
  check int "no aggregated WARN emitted" 0 (List.length warns)

let () =
  run "keeper_prompt_personality_field_aggregation"
    [
      ( "F-3 personality WARN aggregation",
        [
          test_case "3 empty fields -> 1 WARN naming all 3" `Quick
            test_all_three_fields_empty_emits_single_warn_with_all_names;
          test_case "1 empty field  -> 1 WARN naming only that field"
            `Quick
            test_single_field_empty_emits_single_warn_with_one_name;
          test_case "0 empty fields -> 0 WARN" `Quick
            test_no_empty_fields_emits_no_warn;
        ] );
    ]
