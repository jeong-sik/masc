(* See server_dashboard_http_keeper_get_route.mli. *)

module Types = Server_dashboard_http_keeper_api_types

type keeper_route =
  | Metrics
  | Github_identity
  | Board_attention_quarantines
  | Chat_history_page
  | Chat_history
  | Checkpoints
  | File_changes
  | Paused_work
  | Runtime_trace
  | Config
  | Tool_stats
  | Tool_result
  | Tool_calls
  | Waiting_inventory
  | Feedback
  | Working_context
  | Memory_facts
  | Memory_journal
  | Operator_note
  | Next_request
  | Last_prompt
  | Provider_input_continuity
  | Provider_input_part
  | Provider_input
  | Raw_traces
  | Raw_trace
  | Turn_records
  | Turn_transcript
  | Trajectory
  | Transitions
  | Lifecycle
  | Eval
  | State_diagram
  | Composite
[@@deriving enumerate]

type t =
  | Fleet_composite
  | Keeper of keeper_route * string

let all = all_of_keeper_route

(* A suffix the types module already names is taken from there. *)
let suffix = function
  | Metrics -> "/metrics"
  | Github_identity -> Types.keeper_suffix_github_identity
  | Board_attention_quarantines -> Types.keeper_suffix_board_attention_quarantines
  | Chat_history_page -> "/chat/history/page"
  | Chat_history -> "/chat/history"
  | Checkpoints -> Types.keeper_suffix_checkpoints
  | File_changes -> Types.keeper_suffix_file_changes
  | Paused_work -> Types.keeper_suffix_paused_work
  | Runtime_trace -> Types.keeper_suffix_runtime_trace
  | Config -> Types.keeper_suffix_config
  | Tool_stats -> "/tool-stats"
  | Tool_result -> "/tool-result"
  | Tool_calls -> "/tool-calls"
  | Waiting_inventory -> "/waiting-inventory"
  | Feedback -> "/feedback"
  | Working_context -> Types.keeper_suffix_working_context
  | Memory_facts -> "/memory-facts"
  | Memory_journal -> "/memory-journal"
  | Operator_note -> Types.keeper_suffix_operator_note
  | Next_request -> "/next-request"
  | Last_prompt -> "/last-prompt"
  | Provider_input_continuity -> Types.keeper_suffix_provider_input_continuity
  | Provider_input_part -> Types.keeper_suffix_provider_input_part
  | Provider_input -> Types.keeper_suffix_provider_input
  | Raw_traces -> "/raw-traces"
  | Raw_trace -> "/raw-trace"
  | Turn_records -> "/turn-records"
  | Turn_transcript -> "/turn-transcript"
  | Trajectory -> "/trajectory"
  | Transitions -> "/transitions"
  | Lifecycle -> "/lifecycle"
  | Eval -> "/eval"
  | State_diagram -> "/state-diagram"
  | Composite -> "/composite"
;;

let fleet_composite_path = Types.keeper_api_prefix ^ "composite"

let of_path path =
  let prefix = Types.keeper_api_prefix in
  if not (String.starts_with ~prefix path)
  then None
  else if String.equal path fleet_composite_path
  then Some Fleet_composite
  else (
    let plen = String.length prefix in
    let tlen = String.length path in
    List.find_map
      (fun route ->
         let tail = suffix route in
         let slen = String.length tail in
         if tlen > plen + slen && String.ends_with ~suffix:tail path
         then (
           match String.trim (String.sub path plen (tlen - plen - slen)) with
           | "" -> None
           | name -> Some (Keeper (route, name)))
         else None)
      all)
;;

(* HIGH-RISK-UNREVIEWED: this match decides which keeper GET routes need a
   token.

   A route's permission is decided here and nowhere else: deciding it
   somewhere else is how two doors onto the same data ended up with different
   gates. [Raw_trace] requires [CanAdmin] because it returns hidden reasoning;
   [Trajectory] with [include_thinking] returns the same reasoning and once
   required nothing. Same data, same gate. *)
let permission ?(include_thinking = false) = function
  | Fleet_composite -> None
  | Keeper (route, _name) ->
    (match route with
     | Trajectory -> if include_thinking then Some Masc_domain.CanAdmin else None
     | Turn_records | Metrics -> Some Masc_domain.CanReadState
     | Checkpoints
     | Paused_work
     | Github_identity
     | Raw_traces
     | Raw_trace
     (* A part and the continuity record are items of the request the list
        door describes. *)
     | Provider_input
     | Provider_input_part
     | Provider_input_continuity
     | Memory_journal
     (* The fact rows are the journal's committed content, read back as the
        current set. *)
     | Memory_facts
     | Working_context
     (* [File_changes] returns the exact text a keeper wrote to a file, which
        is part of what the raw trace already holds. A lighter gate here would
        be a second door onto the first door's content. *)
     | File_changes
     (* Both tail and exact execution lookup return raw tool arguments and
        results, so query parameters cannot select a weaker door onto the same
        bytes. *)
     | Tool_calls
     | Tool_result -> Some Masc_domain.CanAdmin
     | Board_attention_quarantines
     | Chat_history_page
     | Chat_history
     | Runtime_trace
     | Config
     | Tool_stats
     | Waiting_inventory
     | Feedback
     | Operator_note
     | Next_request
     | Last_prompt
     | Turn_transcript
     | Transitions
     | Lifecycle
     | Eval
     | State_diagram
     | Composite -> None)
;;
