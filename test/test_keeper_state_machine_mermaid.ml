open Alcotest
module SM = Masc_mcp.Keeper_state_machine

(** Returns all lines of the Mermaid output for a given current phase. *)
let mermaid_lines phase = Masc_mcp.Keeper_state_machine_mermaid.phase_to_mermaid ~current:phase |> String.split_on_char '\n'

(** Returns true if [needle] appears as a substring of [haystack]. *)
let string_contains haystack needle =
  let hl = String.length haystack
  and nl = String.length needle in
  if nl = 0
  then true
  else if hl < nl
  then false
  else (
    let found = ref false in
    for i = 0 to hl - nl do
      if (not !found) && String.sub haystack i nl = needle then found := true
    done;
    !found)
;;

let test_mermaid_header () =
  let lines = mermaid_lines SM.Running in
  check string "starts with stateDiagram-v2" "stateDiagram-v2" (List.nth lines 0)
;;

let test_mermaid_all_phases_appear () =
  List.iter
    (fun phase ->
       let diagram = Masc_mcp.Keeper_state_machine_mermaid.phase_to_mermaid ~current:phase in
       let id = Masc_mcp.Keeper_state_machine_mermaid.phase_to_mermaid_id phase in
       check
         bool
         (Printf.sprintf "phase %s appears in diagram" id)
         true
         (string_contains diagram id))
    SM.all_phases
;;

let class_lines_for lines id =
  let prefix = Printf.sprintf "    class %s " id in
  List.filter
    (fun l ->
       String.length l >= String.length prefix
       && String.sub l 0 (String.length prefix) = prefix)
    lines
;;

let test_mermaid_active_class () =
  let active_phases = [ SM.Offline; SM.Running; SM.Paused ] in
  List.iter
    (fun phase ->
       let lines = mermaid_lines phase in
       let id = Masc_mcp.Keeper_state_machine_mermaid.phase_to_mermaid_id phase in
       let cls = class_lines_for lines id in
       check
         int
         (Printf.sprintf "phase %s has exactly one class line" id)
         1
         (List.length cls);
       check
         bool
         (Printf.sprintf "phase %s assigned active class" id)
         true
         (List.mem (Printf.sprintf "    class %s active" id) cls))
    active_phases
;;

let test_mermaid_buffer_class () =
  let buffer_phases =
    [ SM.Failing; SM.Compacting; SM.HandingOff; SM.Draining; SM.Restarting ]
  in
  List.iter
    (fun phase ->
       let lines = mermaid_lines phase in
       let id = Masc_mcp.Keeper_state_machine_mermaid.phase_to_mermaid_id phase in
       let cls = class_lines_for lines id in
       check
         int
         (Printf.sprintf "phase %s has exactly one class line" id)
         1
         (List.length cls);
       check
         bool
         (Printf.sprintf "phase %s assigned buffer class (not active)" id)
         true
         (List.mem (Printf.sprintf "    class %s buffer" id) cls))
    buffer_phases
;;

let test_mermaid_terminal_class () =
  let terminal_phases = [ SM.Stopped; SM.Dead ] in
  List.iter
    (fun phase ->
       let lines = mermaid_lines phase in
       let id = Masc_mcp.Keeper_state_machine_mermaid.phase_to_mermaid_id phase in
       let cls = class_lines_for lines id in
       check
         int
         (Printf.sprintf "phase %s has exactly one class line" id)
         1
         (List.length cls);
       check
         bool
         (Printf.sprintf "phase %s assigned terminal class" id)
         true
         (List.mem (Printf.sprintf "    class %s terminal" id) cls))
    terminal_phases
;;

let () =
  run "keeper_state_machine_mermaid"
    [ ( "mermaid"
      , [ test_case "header is stateDiagram-v2" `Quick test_mermaid_header
        ; test_case "all phases appear in diagram" `Quick test_mermaid_all_phases_appear
        ; test_case "active phases get active class only" `Quick test_mermaid_active_class
        ; test_case "buffer phases get buffer class only" `Quick test_mermaid_buffer_class
        ; test_case
            "terminal phases get terminal class only"
            `Quick
            test_mermaid_terminal_class
        ] )
    ]
;;
