(* The TUI reads GET /api/v1/dashboard/keeper-costs with a decoder written by
   hand against the server's encoder. These cases write turn rows to a
   workspace, run the server's own [keeper_cost_aggregates_json] over them,
   wrap it the way the cached route does, and feed that to the decoder, so a
   field the server renames turns this suite red instead of blanking the
   Team block's tags. The unknown cases pin the one rule that matters: a
   turn whose runtime reported no cost is never drawn as $0. *)

open Alcotest
module Route = Server_routes_http_routes_provider_runs
module Spend = Masc_tui_keeper_spend
module Keeper_metrics_record = Masc.Keeper_metrics_record
module Keeper_types_support = Masc.Keeper_types_support
open Masc_tui_types

let test_counter = ref 0

let temp_dir () =
  incr test_counter;
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tui_keeper_spend_%d_%d_%d" (Unix.getpid ()) !test_counter
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  (try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  path

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ ("name", `String name); ("trace_id", `String ("trace-" ^ name)) ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)

let usage_of = function
  | Some total ->
      `Assoc
        [ ("input_tokens", `Int (total / 2))
        ; ("output_tokens", `Int (total - (total / 2)))
        ; ("total_tokens", `Int total)
        ]
  | None ->
      `Assoc [ ("input_tokens", `Null); ("output_tokens", `Null); ("total_tokens", `Null) ]

let turn_row ~cost ~tokens =
  Keeper_metrics_record.fields Keeper_metrics_record.Turn
  @ [ ("ts_unix", `Float (Unix.gettimeofday () -. 1.0))
    ; ("channel", `String "turn")
    ; ("cost_usd", match cost with Some usd -> `Float usd | None -> `Null)
    ; ("latency_ms", `Int 100)
    ; ("usage", usage_of tokens)
    ]

(* Keeper name and the (cost, tokens) of each of its turns. *)
let fleet =
  [ ("priced", [ (Some 0.25, Some 15); (Some 0.5, Some 10) ])
  ; ("subscription", [ (None, Some 2_000_000); (None, Some 1_500_000) ])
  ; ("mixed", [ (Some 1.25, Some 400); (None, None) ])
  ; ("quiet", [])
  ]

let mkdir_p dir =
  let rec go dir =
    if not (Sys.file_exists dir) then (
      go (Filename.dirname dir);
      Unix.mkdir dir 0o755)
  in
  go dir

(* A line written straight into the day file of [ts], the way a torn write
   would leave it. *)
let write_raw_line config name ~ts line =
  let base_dir = Dated_jsonl.base_dir (Keeper_types_support.keeper_metrics_store config name) in
  let dated = Jsonl_writer.dated_path ~base_dir ~ts in
  mkdir_p (Filename.dirname dated.path);
  let out = open_out_gen [ Open_append; Open_creat ] 0o644 dated.path in
  output_string out line;
  output_char out '\n';
  close_out out

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_eio_clock env;
  let config = Masc.Workspace.default_config (temp_dir ()) in
  ignore (Masc.Workspace.init config ~agent_name:None);
  f config

let append_turns config name turns =
  List.iter
    (fun (cost, tokens) ->
      Dated_jsonl.append
        (Keeper_types_support.keeper_metrics_store config name)
        (`Assoc (turn_row ~cost ~tokens)))
    turns

(* The server's own answer for [keepers], wrapped with the cache object the
   route appends. *)
let server_answer ?(state = Route.Cache_fresh) ?age_s ?error config names =
  let body =
    Dashboard_http_keeper.keeper_cost_aggregates_json ~config
      ~keepers:(List.map make_meta names) ~window_minutes:Spend.window_minutes
      ~now_ts:(Unix.gettimeofday ())
  in
  Route.json_with_cache_metadata body
    (Route.cache_metadata ~state ~generated_at:(Unix.gettimeofday ()) ?age_s ?error ())

let server_json ?state ?age_s ?error () =
  with_workspace (fun config ->
      List.iter (fun (name, turns) -> append_turns config name turns) fleet;
      server_answer ?state ?age_s ?error config (List.map fst fleet))

let decode json =
  match Spend.decode_reading json with
  | Ok reading -> reading
  | Error err -> failf "the server's own JSON did not decode: %s" err

let strip text =
  let buf = Buffer.create (String.length text) in
  let rec go i =
    if i >= String.length text then ()
    else if Char.equal text.[i] '\027' then (
      let j = ref (i + 1) in
      while !j < String.length text && not (Char.equal text.[!j] 'm') do incr j done;
      go (!j + 1))
    else (
      Buffer.add_char buf text.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents buf

let names = List.map fst fleet @ [ "unlisted" ]

let sum_pp pp fmt = function
  | Spend_unknown -> Format.fprintf fmt "unknown"
  | Spend_sum { sum; missing } -> Format.fprintf fmt "%a (missing %d)" pp sum missing

let spend_testable =
  testable
    (fun fmt (spend : keeper_spend) ->
      match spend with
      | Spend_no_turns -> Format.fprintf fmt "no turns"
      | Spend_unread reason -> Format.fprintf fmt "unread: %s" reason
      | Spend_turns { cost_usd; tokens } ->
          Format.fprintf fmt "cost %a, tokens %a"
            (sum_pp (fun fmt -> Format.fprintf fmt "%.4f")) cost_usd
            (sum_pp Format.pp_print_int) tokens)
    ( = )

let read_keepers reading =
  match reading with
  | Overview_spend_read { keepers; _ } -> keepers
  | Overview_spend_unread | Overview_spend_warming | Overview_spend_failed _ ->
      fail "a fresh answer decodes as read"

let test_server_json_decodes_per_keeper () =
  match decode (server_json ()) with
  | Overview_spend_read { window_minutes; keepers; undecodable; freshness } ->
      check int "the window asked for is the window answered" Spend.window_minutes
        window_minutes;
      check int "every row decodes" 0 undecodable;
      check bool "a fresh answer is fresh" true (freshness = Spend_fresh);
      let spend name =
        match List.assoc_opt name keepers with
        | Some spend -> spend
        | None -> failf "%s is missing from the decoded rows" name
      in
      check spend_testable "priced turns sum"
        (Spend_turns
           { cost_usd = Spend_sum { sum = 0.75; missing = 0 }
           ; tokens = Spend_sum { sum = 25; missing = 0 }
           })
        (spend "priced");
      check spend_testable "turns without a cost stay unknown, not 0"
        (Spend_turns
           { cost_usd = Spend_unknown; tokens = Spend_sum { sum = 3_500_000; missing = 0 } })
        (spend "subscription");
      check spend_testable "a turn without a cost makes the sum a floor"
        (Spend_turns
           { cost_usd = Spend_sum { sum = 1.25; missing = 1 }
           ; tokens = Spend_sum { sum = 400; missing = 1 }
           })
        (spend "mixed");
      check spend_testable "no turns is its own reading" Spend_no_turns (spend "quiet")
  | _ -> fail "a fresh answer decodes as read"

let test_tags_draw_known_floor_and_unknown () =
  let tag = Spend.keeper_tags (decode (server_json ())) names in
  let tag name = strip (tag name) in
  check string "a priced Keeper's cost and tokens" "$0.75 25 tok   " (tag "priced");
  check string "an unpriced Keeper draws tokens only, never $0" "3.5M tok       "
    (tag "subscription");
  check string "a partly priced Keeper draws a floor" "\xe2\x89\xa5$1.25 \xe2\x89\xa5400 tok"
    (tag "mixed");
  check string "a Keeper with no turns says so" "no turns       " (tag "quiet");
  check string "a Keeper the server did not list is unknown" "? tok          "
    (tag "unlisted");
  let widths =
    List.sort_uniq compare
      (List.map (fun name -> Masc_tui_message_layout.display_width (tag name)) names)
  in
  check (list int) "every tag takes the same cells" [ 15 ] widths

let total reading names =
  match Spend.team_total reading names with
  | total :: _ -> strip total
  | [] -> fail "a read answer over the block's Keepers has a team total"

let test_team_total () =
  let reading = decode (server_json ()) in
  check string "the total over the fleet is a floor"
    "24h \xe2\x89\xa5$2.00 \xe2\x89\xa53.5M tok"
    (total reading (List.map fst fleet));
  check string "a team that reported no cost draws tokens only" "24h 3.5M tok"
    (total reading [ "subscription" ]);
  check string "a team whose drawn Keepers had no turns says so" "24h no turns"
    (total reading [ "quiet" ])

(* A Keeper the block draws but the rows do not account for -- its meta read
   failed, or it was created after the cached answer -- is spend nobody
   read. The title must not look exact beside its "? tok" row. *)
let test_team_total_counts_a_drawn_keeper_missing_from_the_rows () =
  let reading = decode (server_json ()) in
  check string "an exact Keeper plus an unlisted one is a floor"
    "24h \xe2\x89\xa5$0.75 \xe2\x89\xa525 tok"
    (total reading [ "priced"; "unlisted" ]);
  check string "only unlisted Keepers are unknown" "24h ? tok"
    (total reading [ "unlisted" ])

(* A fresh answer with no rows is not a team that spent nothing. *)
let test_team_total_of_an_empty_answer_is_unknown () =
  let reading = with_workspace (fun config -> decode (server_answer config [])) in
  check (list string) "the answer has no rows" [] (List.map fst (read_keepers reading));
  check string "the drawn Keepers are unknown, not idle" "24h ? tok"
    (total reading [ "priced"; "subscription" ]);
  check (list string) "a block with no Keepers has no total" []
    (Spend.team_total reading [])

(* Each word the route can send, and what the Team block does with it. *)
let test_every_cache_state_decodes () =
  List.iter
    (fun state ->
      let label = Route.cache_state_to_string state in
      match state with
      | Route.Cache_fresh -> (
          match decode (server_json ~state ()) with
          | Overview_spend_read { freshness = Spend_fresh; _ } -> ()
          | _ -> failf "%s decodes as a fresh read" label)
      | Route.Cache_stale_refreshing -> (
          match decode (server_json ~state ~age_s:95.0 ~error:"EIO" ()) with
          | Overview_spend_read
              { freshness = Spend_stale { age_s; last_error = Some "EIO" }; _ } as reading
            ->
              check (float 0.001) "the age survives" 95.0 age_s;
              check (list string) "the title's forms: the whole total, then its age"
                [ "24h, 1m old \xe2\x89\xa5$0.75 \xe2\x89\xa525 tok"; "24h, 1m old" ]
                (List.map strip (Spend.team_total reading [ "priced"; "unlisted" ]));
              check (list string) "the failed refresh is said"
                [ "$ spend is 1m old, refresh failed: EIO" ]
                (List.map strip (Spend.lines reading))
          | _ -> failf "%s with an error decodes as stale with it" label)
      | Route.Cache_warming -> (
          (* A warming answer carries the placeholder: its empty rows say
             nothing, so it must not read as "no Keeper spent anything". *)
          let placeholder ?error () =
            with_workspace (fun config -> server_answer ~state ?error config [])
          in
          (match decode (placeholder ()) with
           | Overview_spend_warming -> ()
           | _ -> failf "%s decodes as warming" label);
          match decode (placeholder ~error:"EACCES" ()) with
          | Overview_spend_failed err ->
              check bool "the error is carried" true
                (String.ends_with ~suffix:"EACCES" err)
          | _ -> failf "%s with an error decodes as a failure" label))
    [ Route.Cache_fresh; Route.Cache_stale_refreshing; Route.Cache_warming ]

let test_not_read_draws_no_tag_and_one_line () =
  List.iter
    (fun (reading, label) ->
      check string (label ^ ": no tag") "" (Spend.keeper_tags reading names "priced");
      check (list string) (label ^ ": no total") [] (Spend.team_total reading names))
    [ (Overview_spend_unread, "unread")
    ; (Overview_spend_warming, "warming")
    ; (Overview_spend_failed "refused", "failed")
    ];
  check int "warming says so in one line" 1
    (List.length (Spend.lines Overview_spend_warming));
  check (list string) "a failure says why"
    [ "$ spend unread: refused" ]
    (List.map strip (Spend.lines (Overview_spend_failed "refused")))

(* The refresh applies this: a failed fetch after a good one replaces it. *)
let test_a_failed_load_replaces_the_last_good_reading () =
  let good = Spend.reading_of_load (Ok (decode (server_json ()))) in
  (match good with
   | Overview_spend_read _ -> ()
   | _ -> fail "a good load is read");
  match Spend.reading_of_load (Error "HTTP 503") with
  | Overview_spend_failed "HTTP 503" -> ()
  | _ -> fail "a failed load is the failure, not the last good reading"

(* A row that is not JSON may have been a turn: the sums are floors. A store
   the server could not read is unknown and said under the block. *)
let test_torn_and_unreadable_stores () =
  let reading =
    with_workspace (fun config ->
        let now = Unix.gettimeofday () in
        append_turns config "exact" [ (Some 0.5, Some 10) ];
        append_turns config "torn" [ (Some 0.5, Some 10) ];
        write_raw_line config "torn" ~ts:now "{\"ts_unix\":";
        append_turns config "broken" [ (Some 0.5, Some 10) ];
        let base_dir =
          Dated_jsonl.base_dir (Keeper_types_support.keeper_metrics_store config "broken")
        in
        let dated = Jsonl_writer.dated_path ~base_dir ~ts:now in
        Sys.remove dated.path;
        Unix.mkdir dated.path 0o755;
        decode (server_answer config [ "exact"; "torn"; "broken" ]))
  in
  let tag = Spend.keeper_tags reading [ "torn"; "broken" ] in
  check string "a torn row makes the sums floors" "\xe2\x89\xa5$0.50 \xe2\x89\xa510 tok"
    (strip (tag "torn"));
  check bool "an unreadable store is unknown" true
    (String.starts_with ~prefix:"? tok" (strip (tag "broken")));
  check string "an unread store makes an exact Keeper's total a floor"
    "24h \xe2\x89\xa5$0.50 \xe2\x89\xa510 tok"
    (total reading [ "exact"; "broken" ]);
  check bool "the unreadable store is said" true
    (List.exists
       (String.starts_with ~prefix:"$ spend unread for 1 Keeper: ")
       (List.map strip (Spend.lines reading)))

(* A row this build cannot read leaves its Keeper unknown and is counted;
   the other rows still draw. *)
let test_unreadable_row_is_unknown () =
  let json =
    match server_json () with
    | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) ->
               match (key, value) with
               | "keepers", `List rows ->
                   ( key
                   , `List
                       (List.map
                          (fun row ->
                            match Yojson.Safe.Util.member "keeper_name" row with
                            | `String "priced" ->
                                `Assoc
                                  [ ("keeper_name", `String "priced")
                                  ; ("sample_count", `Int 2)
                                  ]
                            | _ -> row)
                          rows) )
               | _ -> (key, value))
             fields)
    | _ -> fail "the route answers an object"
  in
  let reading = decode json in
  (match reading with
   | Overview_spend_read { undecodable; _ } -> check int "the bad row is counted" 1 undecodable
   | _ -> fail "one bad row does not fail the reading");
  let tag name = strip (Spend.keeper_tags reading names name) in
  check bool "its Keeper is unknown" true (String.starts_with ~prefix:"? tok" (tag "priced"));
  check bool "another Keeper still draws" true
    (String.starts_with ~prefix:"3.5M tok" (tag "subscription"));
  check (list string) "the count is said under the block"
    [ "$ spend unknown for 1 unreadable Keeper row" ]
    (List.map strip (Spend.lines reading))

(* The tag goes at the right of the row only where the row still fits whole:
   a stuck Keeper's cause is drawn nowhere else, so a narrow row keeps it
   and drops the spend. *)
let test_a_narrow_row_keeps_its_detail () =
  let row = "! k-stuck crashed 3m  token expired for the github connector" in
  let tag = "1.2M tok" in
  let narrow = Spend.place_tag ~inner:52 ~tag row in
  check string "the detail is whole and the tag is gone" row narrow;
  let wide = Spend.place_tag ~inner:128 ~tag row in
  check int "a wide row spans the frame" 128 (Masc_tui_message_layout.display_width wide);
  check bool "a wide row starts with its detail" true (String.starts_with ~prefix:row wide);
  check bool "a wide row ends with the tag" true (String.ends_with ~suffix:tag wide);
  check string "an empty tag leaves the row alone" row (Spend.place_tag ~inner:128 ~tag:"" row);
  let exact =
    Masc_tui_message_layout.display_width row + Spend.tag_gap_cells
    + Masc_tui_message_layout.display_width tag
  in
  check bool "a row that fits with its gap exactly takes the tag" true
    (String.ends_with ~suffix:tag (Spend.place_tag ~inner:exact ~tag row));
  check string "a row one cell short of its gap drops the tag" row
    (Spend.place_tag ~inner:(exact - 1) ~tag row);
  (* The spec, not the constant: a tag never sits closer than two blank
     cells to the detail, so a frame with room for only one drops it. *)
  let one_cell_gap =
    Masc_tui_message_layout.display_width row + 1 + Masc_tui_message_layout.display_width tag
  in
  check string "a tag never sits one cell from the detail" row
    (Spend.place_tag ~inner:one_cell_gap ~tag row)

(* The title's total covers the parked roll call as well as the rows: the
   render passes both. A parked Keeper that spent is in the figure, and one
   whose row could not be read makes it a floor. *)
let test_team_total_covers_parked_keepers () =
  let reading = decode (server_json ()) in
  let rows = [ "subscription" ] and parked = [ "priced" ] in
  check string "a parked Keeper's spend is in the total"
    "24h \xe2\x89\xa5$0.75 3.5M tok" (total reading (rows @ parked));
  check string "a parked Keeper nobody read makes it a floor"
    "24h \xe2\x89\xa53.5M tok" (total reading (rows @ [ "unlisted" ]))

let head = " Team  1 need you \xc2\xb7 1 working \xc2\xb7 1 idle \xc2\xb7 1 parked"
let full = "24h, 12m old \xe2\x89\xa5$123.45 \xe2\x89\xa5123.4M tok"
let marker = "24h, 12m old"
let spark = "   14d \xe2\x96\x81\xe2\x96\x81\xe2\x96\x81 today 0"

(* At 80 columns the total does not fit beside these counts: it is dropped
   whole, the stale fact stays, and no figure is cut. *)
let test_title_sheds_the_total_whole () =
  let fit cols = Spend.fit_title ~cols ~head ~forms:[ full; marker ] ~tails:[ spark ] in
  let at_80 = fit 80 in
  check bool "the title fits 80 cells" true (Masc_tui_message_layout.display_width at_80 <= 80);
  check bool "no figure is drawn in part" false (String.contains at_80 '$');
  check string "at 80 the title is the counts and the answer's age"
    (head ^ Spend.title_gap ^ marker) at_80;
  check string "wide enough, the tail goes before the total"
    (head ^ Spend.title_gap ^ full)
    (fit (Masc_tui_message_layout.display_width (head ^ Spend.title_gap ^ full)));
  check string "wider, everything" (head ^ Spend.title_gap ^ full ^ spark) (fit 200);
  check string "too narrow for any form, the counts alone" head
    (fit (Masc_tui_message_layout.display_width head))

let () =
  run "tui_keeper_spend"
    [ ( "server JSON"
      , [ test_case "per-keeper spend decodes" `Quick test_server_json_decodes_per_keeper
        ; test_case "tags draw known, floor and unknown" `Quick
            test_tags_draw_known_floor_and_unknown
        ; test_case "team total" `Quick test_team_total
        ; test_case "team total counts a drawn Keeper missing from the rows" `Quick
            test_team_total_counts_a_drawn_keeper_missing_from_the_rows
        ; test_case "team total of an empty answer is unknown" `Quick
            test_team_total_of_an_empty_answer_is_unknown
        ; test_case "every cache state decodes" `Quick test_every_cache_state_decodes
        ; test_case "not read draws no tag" `Quick test_not_read_draws_no_tag_and_one_line
        ; test_case "a failed load replaces the last good reading" `Quick
            test_a_failed_load_replaces_the_last_good_reading
        ; test_case "torn and unreadable stores" `Quick test_torn_and_unreadable_stores
        ; test_case "an unreadable row is unknown" `Quick test_unreadable_row_is_unknown
        ; test_case "a narrow row keeps its detail" `Quick test_a_narrow_row_keeps_its_detail
        ; test_case "team total covers parked Keepers" `Quick
            test_team_total_covers_parked_keepers
        ; test_case "the title sheds the total whole" `Quick test_title_sheds_the_total_whole
        ] )
    ]
