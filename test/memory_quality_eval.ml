(** Memory-quality eval harness — offline, deterministic, read-only.

    Harness-First (MANIFEST): a forgetting policy's decay constant or
    mechanism is an unproven scoring layer until an eval measures memory
    quality. This harness measures, from the recall-injection ledger, how
    badly keeper memory re-injects the same fact every turn (the echo loop
    RFC-0285 targets) so a change can be evaluated before/after, not asserted.

    Measures: echo rate (a fact_key re-injected across turns), recall churn,
    near-duplicate slot fragmentation, and — when a fact store is present —
    fact composition. Reuses [Masc.Keeper_memory_os_types] keying so a
    "duplicate" here is one the live dedup boundary actually keeps.

    Measurement-only: it classifies nothing into any policy. Near-duplicate
    grouping is a labeled heuristic for a human to read, NOT a recall-time
    string classifier (CLAUDE.md workaround signature #2).

    Run:
      dune exec test/memory_quality_eval.exe                       (self-test)
      dune exec test/memory_quality_eval.exe -- --recall-dir <dir> (baseline)
      ... [--keepers-dir <dir>] [--top N]                                    *)

module Types = Masc.Keeper_memory_os_types

(* ---------- output / counters ---------- *)

let passed = ref 0
let failed = ref 0

let check msg cond =
  if cond then incr passed
  else (
    incr failed;
    Printf.printf "  x FAIL: %s\n%!" msg)
;;

let section title = Printf.printf "\n=== %s ===\n%!" title
let note fmt = Printf.ksprintf (fun s -> Printf.printf "  . %s\n%!" s) fmt
let pct n total = if total = 0 then 0.0 else 100.0 *. float_of_int n /. float_of_int total

(* default number of rows to print in top-N listings. *)
let default_top_n = 15

(* ---------- recall record ---------- *)

type recall_record =
  { keeper_id : string
  ; turn : int
  ; fact_keys : string list
  ; n_facts_in_store : int
  }

let parse_recall_line line : recall_record option =
  match Yojson.Safe.from_string line with
  | `Assoc fields ->
    let str k =
      match List.assoc_opt k fields with Some (`String s) -> Some s | _ -> None
    in
    let int k =
      match List.assoc_opt k fields with
      | Some (`Int i) -> Some i
      | Some (`Float f) -> Some (int_of_float f)
      | _ -> None
    in
    let strlist k =
      match List.assoc_opt k fields with
      | Some (`List l) ->
        List.filter_map (function `String s -> Some s | _ -> None) l
      | _ -> []
    in
    (match str "keeper_id", int "turn" with
     | Some keeper_id, Some turn ->
       Some
         { keeper_id
         ; turn
         ; fact_keys = strlist "injected_fact_keys"
         ; n_facts_in_store = Option.value (int "n_facts_in_store") ~default:0
         }
     | _ -> None)
  | _ -> None
  | exception _ -> None
;;

(* ---------- IO (read-only) ---------- *)

let read_lines path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let rec loop acc =
         match input_line ic with
         | line -> loop (line :: acc)
         | exception End_of_file -> List.rev acc
       in
       loop [])
;;

(* Sorted, recursive *.jsonl discovery — sorted so output is path-order stable. *)
let rec find_jsonl dir =
  if Sys.file_exists dir && (try Sys.is_directory dir with _ -> false)
  then
    Sys.readdir dir
    |> Array.to_list
    |> List.sort String.compare
    |> List.concat_map (fun name ->
      let path = Filename.concat dir name in
      if (try Sys.is_directory path with _ -> false)
      then find_jsonl path
      else if Filename.check_suffix path ".jsonl"
      then [ path ]
      else [])
  else []
;;

let load_recall_records ~recall_dir =
  find_jsonl recall_dir |> List.concat_map read_lines |> List.filter_map parse_recall_line
;;

(* ---------- echo metrics ---------- *)

(* fact_key -> number of turns it was injected into. A turn that injects the
   same key twice counts twice (the ledger row is a list); in practice keys are
   distinct per row, so this equals turn-count. *)
let echo_counts records =
  let tbl = Hashtbl.create 1024 in
  List.iter
    (fun r ->
       List.iter
         (fun k ->
            Hashtbl.replace tbl k (1 + Option.value (Hashtbl.find_opt tbl k) ~default:0))
         r.fact_keys)
    records;
  tbl
;;

(* count-descending, then key-ascending for a deterministic total order. *)
let counts_desc tbl =
  Hashtbl.fold (fun k c acc -> (k, c) :: acc) tbl []
  |> List.sort (fun (k1, c1) (k2, c2) ->
    if c1 <> c2 then compare c2 c1 else String.compare k1 k2)
;;

let percentile sorted_asc p =
  let n = Array.length sorted_asc in
  if n = 0 then 0 else sorted_asc.(min (n - 1) (int_of_float (p *. float_of_int n)))
;;

(* Pure churn statistics over recall records, extracted so self_test pins the exact
   arithmetic report_churn prints: (mean keys/turn, max keys/turn, max store size).
   Sharing one function avoids a mock-vs-mock test that re-derives the formula. *)
let churn_stats records =
  let keys_per = List.map (fun r -> List.length r.fact_keys) records in
  let store_sizes = List.map (fun r -> r.n_facts_in_store) records in
  let sum l = List.fold_left ( + ) 0 l in
  let avg l = if l = [] then 0.0 else float_of_int (sum l) /. float_of_int (List.length l) in
  let maxl l = List.fold_left max 0 l in
  avg keys_per, maxl keys_per, maxl store_sizes
;;

(* ---------- self-test (the harness's own harness) ---------- *)

let self_test () =
  section "SELF-TEST (synthetic fixtures)";
  let recs =
    [ { keeper_id = "k1"; turn = 1; fact_keys = [ "id:a"; "id:b" ]; n_facts_in_store = 2 }
    ; { keeper_id = "k1"; turn = 2; fact_keys = [ "id:a" ]; n_facts_in_store = 2 }
    ; { keeper_id = "k1"; turn = 3; fact_keys = [ "id:a"; "id:c" ]; n_facts_in_store = 3 }
    ; { keeper_id = "k2"; turn = 1; fact_keys = [ "id:a" ]; n_facts_in_store = 1 }
    ]
  in
  let tbl = echo_counts recs in
  check "echo id:a = 4 (3 k1 + 1 k2)" (Hashtbl.find_opt tbl "id:a" = Some 4);
  check "echo id:b = 1" (Hashtbl.find_opt tbl "id:b" = Some 1);
  check "echo id:c = 1" (Hashtbl.find_opt tbl "id:c" = Some 1);
  let desc = counts_desc tbl in
  check "top key is id:a" (match desc with (k, _) :: _ -> String.equal k "id:a" | [] -> false);
  check "distinct keys = 3" (List.length desc = 3);
  (* pin the full order: count-desc primary AND key-asc tie-break (id:b before id:c).
     Asserting only the head would let a reversed/dropped secondary key pass while
     breaking the byte-identical reproducibility the top-N listing depends on. *)
  check "counts_desc tie-break is key-ascending" (List.map fst desc = [ "id:a"; "id:b"; "id:c" ]);
  let counts_asc = desc |> List.map snd |> List.sort compare |> Array.of_list in
  check "max (p1.0) = 4" (percentile counts_asc 1.0 = 4);
  check "min (p0.0) = 1" (percentile counts_asc 0.0 = 1);
  (* interior percentile indices — the live report emits p50/p90/p99, none of which
     hit the clamp arms the two checks above exercise. Pin the multiply-truncate
     arithmetic so an off-by-one cannot silently corrupt the §8 baseline numbers. *)
  let p10 = [| 1; 2; 3; 4; 5; 6; 7; 8; 9; 10 |] in
  check "percentile p0.5 interior = 6" (percentile p10 0.5 = 6);
  check "percentile p0.9 interior = 10" (percentile p10 0.9 = 10);
  check "percentile p0.99 interior = 10" (percentile p10 0.99 = 10);
  check "parse recall line"
    (match
       parse_recall_line
         {|{"keeper_id":"x","turn":7,"injected_fact_keys":["id:z"],"n_facts_in_store":5}|}
     with
     | Some r ->
       String.equal r.keeper_id "x" && r.turn = 7 && r.fact_keys = [ "id:z" ]
       && r.n_facts_in_store = 5
     | None -> false);
  check "parse junk -> None" (parse_recall_line "not json" = None);
  (* churn arithmetic over the same fixture: keys/turn lengths [2;1;2;1] -> mean 1.5,
     max 2; n_facts_in_store [2;2;3;1] -> max 3. report_churn shares churn_stats. *)
  let mean_kp, max_kp, max_store = churn_stats recs in
  check "churn mean keys/turn = 1.5" (Float.abs (mean_kp -. 1.5) < 1e-9);
  check "churn max keys/turn = 2" (max_kp = 2);
  check "churn max store size = 3" (max_store = 3)
;;

(* ---------- live-baseline reports ---------- *)

let report_echo records ~top_n =
  section "ECHO RATE (fact_key re-injection across turns)";
  let tbl = echo_counts records in
  let desc = counts_desc tbl in
  let counts_asc = desc |> List.map snd |> List.sort compare |> Array.of_list in
  let total_inj = Array.fold_left ( + ) 0 counts_asc in
  note "recall records (turns): %d" (List.length records);
  note "distinct fact_keys: %d" (List.length desc);
  note "total injections: %d" total_inj;
  note "max=%d  p99=%d  p90=%d  p50=%d"
    (percentile counts_asc 1.0)
    (percentile counts_asc 0.99)
    (percentile counts_asc 0.90)
    (percentile counts_asc 0.50);
  Printf.printf "  top %d echoed fact_keys:\n%!" top_n;
  List.iteri (fun i (k, c) -> if i < top_n then Printf.printf "    %6d  %s\n%!" c k) desc
;;

let report_per_keeper records =
  section "PER-KEEPER ECHO";
  let keepers = List.sort_uniq String.compare (List.map (fun r -> r.keeper_id) records) in
  List.iter
    (fun kid ->
       let krecs = List.filter (fun r -> String.equal r.keeper_id kid) records in
       let desc = counts_desc (echo_counts krecs) in
       let maxc, maxk = match desc with (k, c) :: _ -> c, k | [] -> 0, "-" in
       note "%-14s turns=%-5d distinct_keys=%-4d max_echo=%-5d  top: %s"
         kid (List.length krecs) (List.length desc) maxc maxk)
    keepers
;;

let report_churn records =
  section "RECALL CHURN";
  let mean_kp, max_kp, max_store = churn_stats records in
  note "injected fact_keys per turn: mean=%.1f max=%d" mean_kp max_kp;
  note "n_facts_in_store: max=%d" max_store
;;

let load_facts ~keepers_dir =
  if not (Sys.file_exists keepers_dir && (try Sys.is_directory keepers_dir with _ -> false))
  then []
  else
    Sys.readdir keepers_dir
    |> Array.to_list
    |> List.sort String.compare
    |> List.filter_map (fun name ->
      match Filename.chop_suffix_opt ~suffix:".facts.jsonl" name with
      | None -> None
      | Some keeper ->
        let facts =
          read_lines (Filename.concat keepers_dir name)
          |> List.filter_map (fun line ->
            match Yojson.Safe.from_string line with
            | json -> Types.fact_of_json json
            | exception _ -> None)
        in
        Some (keeper, facts))
;;

let report_composition facts =
  section "FACT COMPOSITION (fact store)";
  if facts = []
  then note "no fact store found (keepers/*.facts.jsonl) — composition skipped"
  else (
    let all = List.concat_map snd facts in
    let total = List.length all in
    let durable = List.length (List.filter (fun (f : Types.fact) -> f.valid_until = None) all) in
    let with_id = List.length (List.filter (fun (f : Types.fact) -> f.claim_id <> None) all) in
    note "keepers with fact store: %d" (List.length facts);
    note "total facts: %d" total;
    note "durable (valid_until=None): %d (%.0f%%)" durable (pct durable total);
    note "with claim_id: %d (%.0f%%)" with_id (pct with_id total);
    let idtbl = Hashtbl.create 256 in
    List.iter
      (fun f ->
         let id = Types.claim_identity f in
         Hashtbl.replace idtbl id (1 + Option.value (Hashtbl.find_opt idtbl id) ~default:0))
      all;
    let dups = Hashtbl.fold (fun _ c acc -> if c > 1 then acc + (c - 1) else acc) idtbl 0 in
    note "duplicate rows (same claim_identity): %d" dups)
;;

(* ---------- main ---------- *)

let arg_value flag argv =
  let rec find = function
    | f :: v :: _ when String.equal f flag -> Some v
    | _ :: rest -> find rest
    | [] -> None
  in
  find (Array.to_list argv)
;;

let () =
  Printf.printf
    "MEMORY-QUALITY EVAL HARNESS - offline, deterministic, read-only (Harness-First)\n%!";
  self_test ();
  (match arg_value "--recall-dir" Sys.argv with
   | None ->
     note "no --recall-dir; self-test only (pass --recall-dir <dir> for live baseline)"
   | Some recall_dir ->
     let top_n =
       match arg_value "--top" Sys.argv with
       | Some s -> (try int_of_string s with _ -> default_top_n)
       | None -> default_top_n
     in
     let records = load_recall_records ~recall_dir in
     report_echo records ~top_n;
     report_per_keeper records;
     report_churn records;
     (match arg_value "--keepers-dir" Sys.argv with
      | Some kd -> report_composition (load_facts ~keepers_dir:kd)
      | None -> note "no --keepers-dir; fact composition skipped"));
  Printf.printf "\n=== SUMMARY: %d passed, %d failed ===\n%!" !passed !failed;
  if !failed > 0 then exit 1
;;
