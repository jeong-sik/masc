(** The command gate's verdict log, checked at its sink.

    [log_verdict] reported through the external [logs] library. Nothing in
    this tree ever calls [Logs.set_reporter], so that library keeps its
    default [nop_reporter] and discarded every line: the gate's three
    warn sites were the only [logs] users under lib/, and none of their
    output existed. They now report through [Log.Gate], whose in-memory
    ring is what these cases read.

    The second contract is arity. [gate_raw] used to reach the policy by
    calling [gate_typed], which logs, and then logged again itself — one
    rejected command produced two lines, source=typed and source=raw.
    Nothing surfaced that while the output went nowhere, and restoring
    the sink without splitting the decision out would have made the
    duplicate the visible behaviour. *)

open Alcotest

module Gate = Masc_exec_command_gate.Shell_command_gate
module Ring = Log.Ring

let sandbox = Gate.host_sandbox

let no_pipes : Gate.syntax_policy = { redirect_allowed = false; allow_pipes = false }
let with_pipes : Gate.syntax_policy = { redirect_allowed = false; allow_pipes = true }

(* A rejected two-stage pipeline: the shape test_exec_shell_command_gate
   pins as Pipes_not_allowed { stages = 2 }. *)
let rejected_command = "rg foo | head -20"

(* [since_seq] is exclusive and the ring's first entry carries seq 0, so an
   empty ring has to sit below it rather than at it. *)
let ring_cursor () =
  match Ring.recent ~limit:1 () with
  | entry :: _ -> entry.Ring.seq
  | [] -> -1
;;

(* The Gate entries a single call appends, oldest first. *)
let gate_entries_of run =
  let cursor = ring_cursor () in
  let verdict = run () in
  let entries =
    Ring.recent ~since_seq:cursor ~module_filter:"Gate" ~order:`Oldest_first ()
  in
  verdict, entries
;;

let contains ~needle haystack =
  let hn = String.length haystack and nn = String.length needle in
  let rec go i =
    if i + nn > hn then false
    else if String.sub haystack i nn = needle then true
    else go (i + 1)
  in
  go 0
;;

(* Positive control: if the module filter or the ring were wrong, every
   case below would report "the gate logged nothing" for the wrong
   reason. This pins that Log.Gate reaches the ring at all. *)
let test_ring_receives_gate_logs () =
  let cursor = ring_cursor () in
  Log.Gate.warn "probe %d" 1;
  match Ring.recent ~since_seq:cursor ~module_filter:"Gate" ~order:`Oldest_first () with
  | [ entry ] ->
    check bool "the probe reached the ring" true
      (contains ~needle:"probe 1" entry.Ring.message)
  | other -> failf "expected the probe alone, got %d entries" (List.length other)
;;

let test_allowed_command_logs_nothing () =
  let verdict, entries =
    gate_entries_of (fun () -> Gate.gate_raw ~text:"ls" ~syntax_policy:with_pipes ~sandbox ())
  in
  (match verdict with
   | Gate.Allow _ -> ()
   | other -> failf "expected Allow, got %s" (Gate.verdict_tag other));
  check int "an allowed command logs nothing" 0 (List.length entries)
;;

(* The regression: one call, one line. Before the split this was two. *)
let test_raw_rejection_logs_once () =
  let verdict, entries =
    gate_entries_of (fun () ->
      Gate.gate_raw ~text:rejected_command ~syntax_policy:no_pipes ~sandbox ())
  in
  (match verdict with
   | Gate.Reject _ -> ()
   | other -> failf "expected Reject, got %s" (Gate.verdict_tag other));
  match entries with
  | [ entry ] ->
    check bool
      (Printf.sprintf "the line names the raw entrypoint: %s" entry.Ring.message)
      true
      (contains ~needle:"source=raw" entry.Ring.message);
    check bool "and names the verdict" true
      (contains ~needle:"Shell_command_gate.reject" entry.Ring.message)
  | other ->
    failf
      "gate_raw logged %d lines for one command (%s); it reached the policy \
       through gate_typed and both logged"
      (List.length other)
      (String.concat " | " (List.map (fun e -> e.Ring.message) other))
;;

let test_typed_pipeline_rejection_logs_once () =
  let verdict, entries =
    gate_entries_of (fun () -> Gate.lower_typed_pipeline ~stages:[] ~sandbox ())
  in
  (match verdict with
   | Gate.Cannot_parse _ -> ()
   | other -> failf "expected Cannot_parse for an empty pipeline, got %s" (Gate.verdict_tag other));
  match entries with
  | [ entry ] ->
    check bool
      (Printf.sprintf "the line names the typed-pipeline entrypoint: %s" entry.Ring.message)
      true
      (contains ~needle:"source=typed_pipeline" entry.Ring.message)
  | other -> failf "expected one line, got %d" (List.length other)
;;

let () =
  Alcotest.run
    "Command gate log sink"
    [ ( "sink"
      , [ test_case "Log.Gate reaches the ring" `Quick test_ring_receives_gate_logs
        ; test_case "an allowed command logs nothing" `Quick test_allowed_command_logs_nothing
        ] )
    ; ( "arity"
      , [ test_case "a raw rejection logs once" `Quick test_raw_rejection_logs_once
        ; test_case "a typed-pipeline rejection logs once" `Quick
            test_typed_pipeline_rejection_logs_once
        ] )
    ]
;;
