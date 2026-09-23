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

(* The server's own answer for [fleet], wrapped with the cache word the
   route appends. *)
let server_json ~state =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_eio_clock env;
  let config = Masc.Workspace.default_config (temp_dir ()) in
  ignore (Masc.Workspace.init config ~agent_name:None);
  List.iter
    (fun (name, turns) ->
      List.iter
        (fun (cost, tokens) ->
          Dated_jsonl.append
            (Keeper_types_support.keeper_metrics_store config name)
            (`Assoc (turn_row ~cost ~tokens)))
        turns)
    fleet;
  let body =
    Dashboard_http_keeper.keeper_cost_aggregates_json ~config
      ~keepers:(List.map (fun (name, _) -> make_meta name) fleet)
      ~window_minutes:Spend.window_minutes
  in
  Route.json_with_cache_metadata body
    (Route.cache_metadata ~state ~generated_at:(Unix.gettimeofday ()) ())

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

let spend_testable =
  testable
    (fun fmt (spend : keeper_spend) ->
      let sum pp fmt = function
        | Spend_unknown -> Format.fprintf fmt "unknown"
        | Spend_sum { sum; missing } -> Format.fprintf fmt "%a (missing %d)" pp sum missing
      in
      match spend with
      | Spend_no_turns -> Format.fprintf fmt "no turns"
      | Spend_turns { cost_usd; tokens } ->
          Format.fprintf fmt "cost %a, tokens %a"
            (sum (fun fmt -> Format.fprintf fmt "%.4f")) cost_usd
            (sum Format.pp_print_int) tokens)
    ( = )

let test_server_json_decodes_per_keeper () =
  match decode (server_json ~state:Route.Cache_fresh) with
  | Overview_spend_read { window_minutes; keepers; undecodable } ->
      check int "the window asked for is the window answered" Spend.window_minutes
        window_minutes;
      check int "every row decodes" 0 undecodable;
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

let tags () =
  let tag = Spend.keeper_tags (decode (server_json ~state:Route.Cache_fresh)) names in
  fun name -> strip (tag name)

let test_tags_draw_known_floor_and_unknown () =
  let tag = tags () in
  check string "a priced Keeper's cost and tokens" "$0.75 25 tok     " (tag "priced");
  check string "an unpriced Keeper draws $?, never $0" "$? 3.5M tok      "
    (tag "subscription");
  check string "a partly priced Keeper draws a floor" "\xe2\x89\xa5$1.25 \xe2\x89\xa5400 tok  "
    (tag "mixed");
  check string "a Keeper with no turns says so" "no turns         " (tag "quiet");
  check string "a Keeper the server did not list is unknown" "$? ? tok         "
    (tag "unlisted");
  let widths =
    List.sort_uniq compare
      (List.map (fun name -> Masc_tui_message_layout.display_width (tag name)) names)
  in
  check (list int) "every tag takes the same cells" [ 17 ] widths

let test_team_total () =
  let total =
    match Spend.team_total (decode (server_json ~state:Route.Cache_fresh)) with
    | Some total -> strip total
    | None -> fail "a read answer has a team total"
  in
  check string "the total is a floor over the window" "24h \xe2\x89\xa5$2.00 \xc2\xb7 \xe2\x89\xa53.5M tok"
    total

(* Each word the route can send, and what the Team block does with it. *)
let expected_reading = function
  | Route.Cache_fresh | Route.Cache_stale_refreshing -> `Read
  | Route.Cache_warming -> `Warming

let test_every_cache_state_decodes () =
  List.iter
    (fun state ->
      let label = Route.cache_state_to_string state in
      (* A warming answer carries the placeholder: its empty rows say
         nothing, so it must not read as "no Keeper spent anything". *)
      let body =
        match state with
        | Route.Cache_warming ->
            Route.json_with_cache_metadata
              (Dashboard_http_keeper.keeper_cost_aggregates_json
                 ~config:(Masc.Workspace.default_config (temp_dir ()))
                 ~keepers:[] ~window_minutes:Spend.window_minutes)
              (Route.cache_metadata ~state ~generated_at:0.0 ())
        | Route.Cache_fresh | Route.Cache_stale_refreshing -> server_json ~state
      in
      match (expected_reading state, decode body) with
      | `Read, Overview_spend_read _ | `Warming, Overview_spend_warming -> ()
      | _ -> failf "cache state %s decoded to the wrong reading" label)
    [ Route.Cache_fresh; Route.Cache_stale_refreshing; Route.Cache_warming ]

let test_not_read_draws_no_tag_and_one_line () =
  List.iter
    (fun (reading, label) ->
      check string (label ^ ": no tag") "" (Spend.keeper_tags reading names "priced");
      check (option string) (label ^ ": no total") None (Spend.team_total reading))
    [ (Overview_spend_unread, "unread")
    ; (Overview_spend_warming, "warming")
    ; (Overview_spend_failed "refused", "failed")
    ];
  check int "warming says so in one line" 1
    (List.length (Spend.lines Overview_spend_warming));
  check (list string) "a failure says why"
    [ "$ spend unread: refused" ]
    (List.map strip (Spend.lines (Overview_spend_failed "refused")))

(* A row this build cannot read leaves its Keeper unknown and is counted;
   the other rows still draw. *)
let test_unreadable_row_is_unknown () =
  let json =
    match server_json ~state:Route.Cache_fresh with
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
  check bool "its Keeper is unknown" true (String.starts_with ~prefix:"$? ? tok" (tag "priced"));
  check bool "another Keeper still draws" true
    (String.starts_with ~prefix:"$? 3.5M tok" (tag "subscription"));
  check (list string) "the count is said under the block"
    [ "$ spend rows unreadable: 1 Keeper drawn unknown" ]
    (List.map strip (Spend.lines reading))

let () =
  run "tui_keeper_spend"
    [ ( "server JSON"
      , [ test_case "per-keeper spend decodes" `Quick test_server_json_decodes_per_keeper
        ; test_case "tags draw known, floor and unknown" `Quick
            test_tags_draw_known_floor_and_unknown
        ; test_case "team total" `Quick test_team_total
        ; test_case "every cache state decodes" `Quick test_every_cache_state_decodes
        ; test_case "not read draws no tag" `Quick test_not_read_draws_no_tag_and_one_line
        ; test_case "an unreadable row is unknown" `Quick test_unreadable_row_is_unknown
        ] )
    ]
