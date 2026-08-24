(** The 24h persistence gate asks for the EARLIEST turn row in durable
    history. History is append-only and rotates, so the earliest row routinely
    sits in a rotated segment that a bounded tail read cannot reach.

    Live evidence, 2026-08-09 fleet: every one of the 8 keepers had its first
    turn row in [<keeper>.decisions.jsonl.1], and the tail-only reader reported
    spans of 0.92h-3.07h against true spans of 36h-153h. The gate read 0/8 and
    could not have read otherwise: 24h of rows did not fit in the 512 KB
    window.

    Case [rotated_segment_reached] fails against a tail-only reader; case
    [single_segment_control] passes against either, and exists so a harness
    that reads nothing at all cannot be mistaken for a passing gate. *)

open Masc
module Proof = Dashboard_keeper_decision_log_proof
open Alcotest

let hour = 3600.0

(* ── Fixture helpers ─────────────────────────────── *)

let test_dir () =
  let tmp = Filename.temp_file "masc_persistence_span" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun f -> rm_rf (Filename.concat path f));
      Unix.rmdir path
    end
    else Sys.remove path

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755
  end

let keepers_dir base =
  let dir = Filename.concat base ".masc/keepers" in
  mkdir_p dir;
  dir

(** [write_segment base ~keeper ~rotation rows] writes one decision-log
    segment. [rotation = None] is the current unrotated segment. *)
let write_segment base ~keeper ~rotation rows =
  let dir = keepers_dir base in
  let basename =
    Keeper_runtime_root_entry.basename
      (Keeper_runtime_root_entry.Keeper
         { keeper_name = keeper
         ; artifact = Keeper_runtime_root_entry.Decision_log
         ; rotation
         })
  in
  let oc = open_out (Filename.concat dir basename) in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () ->
      List.iter
        (fun row ->
          output_string oc (Yojson.Safe.to_string row);
          output_char oc '\n')
        rows)

let turn_row ts = `Assoc [ ("channel", `String "turn"); ("ts_unix", `Float ts) ]

let heartbeat_row ts =
  `Assoc [ ("channel", `String "heartbeat"); ("ts_unix", `Float ts) ]

let oversized_heartbeat_row ts =
  `Assoc
    [ ("channel", `String "heartbeat")
    ; ("ts_unix", `Float ts)
    ; ("detail", `String (String.make (600 * 1024) 'x'))
    ]

let evidence ~now ~base ~keeper =
  let config = Workspace.default_config base in
  let stat = Proof.turn_span_stats ~config ~now keeper in
  (stat, Proof.turn_span_evidence_json ~now keeper stat)

let json_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let float_field name json =
  match json_field name json with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None

(* The two ways [has_persistent_turn_span] answers false, told apart. Both are
   correct answers to "was the span proven"; only one of them is an answer
   about the keeper. *)
let reading_name ~now stat =
  match
    Proof.persistent_turn_span_reading
      ~required_span_hours:Proof.persistent_turn_window_hours
      ~now
      stat
  with
  | Proof.Span_met -> "met"
  | Proof.Span_not_met -> "not_met"
  | Proof.Span_undetermined -> "undetermined"

let origin_segment json =
  match json_field "first_ts_origin" json with
  | Some origin -> (
    match json_field "segment" origin with
    | Some (`String s) -> s
    | _ -> "«absent»")
  | None -> "«absent»"

(* ── Cases ───────────────────────────────────────── *)

(* The earliest turn row exists only in the rotated segment; the current
   segment covers barely an hour. A tail-only reader sees ~1h and fails the
   gate on a keeper that has been exchanging turns for two days. *)
let rotated_segment_reached () =
  let base = test_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      let now = 1_700_000_000.0 in
      write_segment base ~keeper:"rotor" ~rotation:(Some 1)
        [ turn_row (now -. (48.0 *. hour))
        ; turn_row (now -. (40.0 *. hour))
        ; turn_row (now -. (2.0 *. hour))
        ];
      write_segment base ~keeper:"rotor" ~rotation:None
        [ turn_row (now -. (1.0 *. hour))
        ; turn_row (now -. (0.5 *. hour))
        ; turn_row (now -. 60.0)
        ];
      let stat, json = evidence ~now ~base ~keeper:"rotor" in
      check bool "gate passes on two days of durable turn exchange" true
        (Proof.has_persistent_turn_span ~now stat);
      check string "a proven span reads as met" "met" (reading_name ~now stat);
      (* 48.0 is asserted as a literal: deriving it from the reader under test
         would make the assertion an identity. *)
      let span = float_field "span_hours" json in
      check bool "span spans the rotated segment, not the tail window" true
        (match span with Some s -> s >= 47.9 && s <= 48.1 | None -> false);
      check string "first_ts is attributed to the rotated segment" "rotated"
        (origin_segment json);
      check (option int) "both segments observed" (Some 2)
        (match json_field "segments_observed" json with
         | Some (`Int n) -> Some n
         | _ -> None))

(* Control: one unrotated segment already spanning 48h. This passes with or
   without rotation support, so a reader that silently returns nothing cannot
   masquerade as a working gate. *)
let single_segment_control () =
  let base = test_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      let now = 1_700_000_000.0 in
      write_segment base ~keeper:"solo" ~rotation:None
        [ turn_row (now -. (48.0 *. hour))
        ; turn_row (now -. (10.0 *. hour))
        ; turn_row (now -. 30.0)
        ];
      let stat, json = evidence ~now ~base ~keeper:"solo" in
      check bool "control: single-segment history passes" true
        (Proof.has_persistent_turn_span ~now stat);
      check string "control: first_ts comes from the current segment" "current"
        (origin_segment json))

let rotated_first_and_single_current_latest_satisfy_tiers () =
  let base = test_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      let now = 1_700_000_000.0 in
      write_segment base ~keeper:"sparse" ~rotation:(Some 1)
        [ turn_row (now -. (5.0 *. hour)) ];
      write_segment base ~keeper:"sparse" ~rotation:None
        [ turn_row (now -. 60.0) ];
      let stat, json = evidence ~now ~base ~keeper:"sparse" in
      check bool "distinct persisted endpoints satisfy the 4h tier" true
        (Proof.has_persistent_turn_span_for ~required_span_hours:4.0 ~now stat);
      check (option int) "current segment contains one recent interaction"
        (Some 1)
        (match json_field "recent_interaction_count" json with
         | Some (`Int n) -> Some n
         | _ -> None);
      check string "first endpoint is attributed to rotated history" "rotated"
        (origin_segment json))

(* Recency is a separate requirement from span: a long history whose last turn
   is a day stale must still fail, or a stopped keeper reads as healthy. *)
let stale_latest_turn_fails () =
  let base = test_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      let now = 1_700_000_000.0 in
      write_segment base ~keeper:"stalled" ~rotation:(Some 1)
        [ turn_row (now -. (100.0 *. hour)); turn_row (now -. (90.0 *. hour)) ];
      write_segment base ~keeper:"stalled" ~rotation:None
        [ turn_row (now -. (31.0 *. hour)); turn_row (now -. (30.0 *. hour)) ];
      let stat, json = evidence ~now ~base ~keeper:"stalled" in
      check bool "long span does not excuse a 30h-old latest turn" false
        (Proof.has_persistent_turn_span ~now stat);
      check bool "span itself is still reported from history" true
        (match float_field "span_hours" json with
         | Some s -> s >= 69.9
         | None -> false))

(* Absence of turn rows is reported as absence, not as a zero-length span. *)
let no_turn_rows_is_explicit () =
  let base = test_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      let now = 1_700_000_000.0 in
      write_segment base ~keeper:"quiet" ~rotation:None
        [ heartbeat_row (now -. (48.0 *. hour)); heartbeat_row (now -. 60.0) ];
      let stat, json = evidence ~now ~base ~keeper:"quiet" in
      check bool "no turn rows cannot satisfy the gate" false
        (Proof.has_persistent_turn_span ~now stat);
      check string "an empty history is an answer about the keeper" "not_met"
        (reading_name ~now stat);
      check string "absence is named, not defaulted" "none" (origin_segment json))

(* A bounded head read is allowed, but exhausting that budget is not evidence
   that history contains no turn rows. Keep the unknown suffix visible so the
   proof fails closed without fabricating absence. *)
let head_budget_exhaustion_is_explicit () =
  let base = test_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      let now = 1_700_000_000.0 in
      write_segment base ~keeper:"bounded" ~rotation:None
        [ oversized_heartbeat_row (now -. (48.0 *. hour))
        ; turn_row (now -. (30.0 *. hour))
        ; turn_row (now -. 60.0)
        ];
      let stat, json = evidence ~now ~base ~keeper:"bounded" in
      check bool "an unscanned suffix cannot satisfy the gate" false
        (Proof.has_persistent_turn_span ~now stat);
      check string "an unscanned suffix leaves the span unknown, not short"
        "undetermined" (reading_name ~now stat);
      check string "budget exhaustion is not collapsed into absence"
        "scan_exhausted" (origin_segment json);
      check (option int) "recent turns remain visible" (Some 2)
        (match json_field "recent_interaction_count" json with
         | Some (`Int n) -> Some n
         | _ -> None))

let post_snapshot_turn_does_not_poison_valid_span () =
  let base = test_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      let now = 1_700_000_000.0 in
      write_segment base ~keeper:"racing" ~rotation:None
        [ turn_row (now -. (48.0 *. hour))
        ; turn_row (now -. 60.0)
        ; turn_row (now +. 1.0)
        ];
      let stat, json = evidence ~now ~base ~keeper:"racing" in
      check bool "valid snapshot-relative span still passes" true
        (Proof.has_persistent_turn_span ~now stat);
      check (option (float 0.0)) "latest excludes the post-snapshot row"
        (Some (now -. 60.0))
        (float_field "latest_ts_unix" json);
      check (option int) "post-snapshot row is not counted"
        (Some 2)
        (match json_field "recent_interaction_count" json with
         | Some (`Int n) -> Some n
         | _ -> None))

let future_only_turns_do_not_prove_persistence () =
  let base = test_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      let now = 1_700_000_000.0 in
      write_segment base ~keeper:"future" ~rotation:None
        [ turn_row (now +. 1.0); turn_row (now +. hour) ];
      let stat, json = evidence ~now ~base ~keeper:"future" in
      check bool "future-only rows fail closed" false
        (Proof.has_persistent_turn_span ~now stat);
      check (option (float 0.0)) "future-only latest remains absent" None
        (float_field "latest_ts_unix" json);
      check string "future-only head is not accepted as history" "none"
        (origin_segment json))

let () =
  run "keeper persistence span history"
    [ ( "turn span"
      , [ test_case "rotated segment is reached" `Quick rotated_segment_reached
        ; test_case "control: single segment" `Quick single_segment_control
        ; test_case "rotated first plus one current latest" `Quick
            rotated_first_and_single_current_latest_satisfy_tiers
        ; test_case "stale latest turn fails" `Quick stale_latest_turn_fails
        ; test_case "no turn rows is explicit" `Quick no_turn_rows_is_explicit
        ; test_case "head budget exhaustion is explicit" `Quick
            head_budget_exhaustion_is_explicit
        ; test_case "post-snapshot row is ignored" `Quick
            post_snapshot_turn_does_not_poison_valid_span
        ; test_case "future-only rows fail closed" `Quick
            future_only_turns_do_not_prove_persistence
        ] )
    ]
