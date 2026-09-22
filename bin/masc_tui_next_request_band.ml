(* The NEXT REQUEST band of the context inspector: the turn's own composition
   run forward by the server (the carried range from the pair's front over
   the durable history), drawn in tokens at the tab's scale. What the marks
   are read against is the provider's count, so it is shown as counted.
   Under the figures, the same parts in the order the request carries them. *)

module Inspector = Masc_tui_context_inspector
open Masc_tui_ansi

let signed_tokens n =
  if n < 0 then "\xe2\x88\x92" ^ Inspector.format_tokens (-n)
  else Inspector.format_tokens n
;;

let origin_sentence = function
  | Inspector.Carried_from_ledger -> "front from this runtime's ledger"
  | Inspector.Carried_from_turn_record { turn } ->
      Printf.sprintf "front from turn #%d's record; nothing counted since the server started" turn
  | Inspector.Carried_halved_after_refusal { retry } ->
      Printf.sprintf "front halved after a refusal (retry %d)" retry
  | Inspector.Carried_evicted_after_refusal { retry } ->
      Printf.sprintf "front evicted after a refusal (retry %d)" retry
  | Inspector.Carried_whole_history -> "no front to start from: the whole history"
;;

(* A Unix epoch as a UTC clock reading, the day dropped: the band compares
   moments within a session, not dates. *)
let clock epoch =
  let seconds = int_of_float epoch mod 86_400 in
  Printf.sprintf "%02d:%02d:%02dZ" (seconds / 3600) (seconds mod 3600 / 60) (seconds mod 60)
;;

let ordinal = function
  | 0 -> "first"
  | 1 -> "second"
  | 2 -> "third"
  | n ->
      let n = n + 1 in
      let suffix =
        if n mod 100 >= 11 && n mod 100 <= 13 then "th"
        else (match n mod 10 with 1 -> "st" | 2 -> "nd" | 3 -> "rd" | _ -> "th")
      in
      Printf.sprintf "%d%s" n suffix
;;

(* Why the candidate walks where it does: the declared order, with a resting
   path moved behind its siblings and named with its release. *)
let walk_sentence ~safe (walk : Inspector.forecast_walk)
    (candidate : Inspector.forecast_candidate) =
  let why =
    match candidate.place.declared_at with
    | Some 0 -> "the declared head"
    | Some n -> Printf.sprintf "declared %s on lane %s" (ordinal n) (safe walk.lane_id)
    | None -> Printf.sprintf "not declared on lane %s" (safe walk.lane_id)
  in
  let rest =
    match candidate.place.rest with
    | Inspector.Rest_serving -> ""
    | Inspector.Rest_resting { release_at; walk_promotes_at_release } ->
        Printf.sprintf "; resting until %s%s" (clock release_at)
          (if walk_promotes_at_release then ", when the walk promotes it" else "")
  in
  Printf.sprintf "Walks %s: %s%s." (ordinal candidate.place.walks_at) why rest
;;

let candidate_lines ~prose ~fact ~safe ~scale ~(walk : Inspector.forecast_walk)
    (candidate : Inspector.forecast_candidate) =
  let tokens_of_bytes = Masc_tui_token_scale.estimate scale in
  let approx bytes = "\xe2\x89\x88" ^ signed_tokens (tokens_of_bytes bytes) in
  let head =
    match candidate.lane with
    | Inspector.Lane_not_applicable reason ->
        fact (safe candidate.runtime_id) @ prose (safe reason ^ ".")
    | Inspector.Lane_agent_core ->
        (match candidate.marks with
         | Some marks ->
             fact
               (Printf.sprintf "%s  \xc2\xb7  marks %s / %s tok" (safe candidate.runtime_id)
                  (Inspector.format_tokens marks.high_water_tokens)
                  (Inspector.format_tokens marks.low_water_tokens))
         | None ->
             fact
               (Printf.sprintf "%s  \xc2\xb7  no marks declared: only a refusal moves the front"
                  (safe candidate.runtime_id)))
  in
  (* The pinned figure names its lane only when it is not this one. *)
  let pinned_provenance (parts : Inspector.forecast_parts) =
    if String.equal parts.pinned_measured_on_runtime candidate.runtime_id
    then Printf.sprintf "(turn #%d)" parts.pinned_measured_on_turn
    else
      Printf.sprintf "(turn #%d on %s)" parts.pinned_measured_on_turn
        (safe parts.pinned_measured_on_runtime)
  in
  let parts_line =
    match candidate.parts with
    | Error reason -> prose ("Fixed parts unknown: " ^ safe reason ^ ".")
    | Ok parts ->
        fact
          (Printf.sprintf "fixed parts %s tok (turn #%d) + pinned %s tok %s"
             (approx parts.reserved_bytes) parts.reserved_measured_on_turn
             (approx parts.pinned_bytes) (pinned_provenance parts))
  in
  let carried_lines =
    match candidate.lane, candidate.carried with
    | Inspector.Lane_not_applicable _, (Some _ | None) -> []
    | Inspector.Lane_agent_core, None ->
        prose
          "No front to start from, and the cap fit charges the fixed parts, which are \
           unknown: no range was computed."
    | Inspector.Lane_agent_core, Some carried ->
        fact
          (Printf.sprintf "%d of %d atoms would go, from atom %d (%s tok)  \xc2\xb7  %s"
             carried.kept_atoms candidate.history_atoms carried.first_atom
             (approx carried.transmitted_bytes) (origin_sentence carried.origin))
        @ (match carried.counted_tokens, candidate.marks with
           | Some counted, Some marks ->
               fact
                 (Printf.sprintf "last counted %s tok against marks %s / %s"
                    (Inspector.format_tokens counted)
                    (Inspector.format_tokens marks.high_water_tokens)
                    (Inspector.format_tokens marks.low_water_tokens))
           | Some counted, None ->
               fact (Printf.sprintf "last counted %s tok" (Inspector.format_tokens counted))
           | None, (Some _ | None) -> [])
  in
  (* The request in the order it travels, one numbered row per slot, the
     [system context] blocks named in the order the assembly concatenates
     them. Only drawn when the server laid it out, which is when both the
     range and the fixed parts were known, and only for the candidate that
     walks first: the others are what the walk would send after a failure. *)
  let assembly_lines =
    match candidate.assembly with
    | None -> []
    | Some _ when candidate.place.walks_at > 0 -> []
    | Some slots ->
        let row index label bytes detail =
          fact
            (Printf.sprintf "%d  %-16s %8s tok%s" (index + 1) label (approx bytes)
               (if String.equal detail "" then "" else "  \xc2\xb7  " ^ detail))
        in
        prose "In the order the request carries them:"
        @ List.concat
            (List.mapi
               (fun index slot ->
                 match slot with
                 | Inspector.Slot_system_prompt { bytes } ->
                     row index "system prompt" bytes "keeper instructions"
                 | Inspector.Slot_tools { bytes } -> row index "tools" bytes "schema surface"
                 | Inspector.Slot_preamble { bytes } ->
                     row index "[context window]" bytes "says older turns are omitted"
                 | Inspector.Slot_history { atoms; of_atoms; bytes } ->
                     row index "history" bytes
                       (Printf.sprintf "%d of %d atoms, oldest first" atoms of_atoms)
                 | Inspector.Slot_wake_line { bytes } -> row index "wake line" bytes "newest atom"
                 | Inspector.Slot_system_context { bytes; blocks } ->
                     row index "[system context]" bytes
                       (String.concat "  \xc2\xb7  "
                          (List.map
                             (fun (name, block_bytes) -> safe name ^ " " ^ approx block_bytes)
                             blocks)))
               slots)
  in
  head @ prose (walk_sentence ~safe walk candidate) @ parts_line @ carried_lines @ assembly_lines
;;

let lines ~prose ~fact ~safe ~scale
    (forecast : (Inspector.forecast, string) result) =
  match forecast with
  | Error detail ->
      [ Theme.bad () ^ "  Next request not forecast: " ^ safe detail ^ Ansi.reset ]
  | Ok forecast ->
      let checkpoint =
        prose
          (Printf.sprintf
             "%d messages in the checkpoint; the wake line adds %s tok as the \
              newest atom."
             forecast.Inspector.checkpoint_messages (Masc_tui_token_scale.format_estimate scale forecast.Inspector.wake_line_bytes))
      in
      (match forecast.Inspector.walk with
       | Error refusal ->
           [ Theme.bad () ^ "  Next request not walked: " ^ safe refusal ^ Ansi.reset ]
           @ checkpoint
       | Ok walk ->
           List.concat_map
             (candidate_lines ~prose ~fact ~safe ~scale ~walk)
             forecast.Inspector.candidates
           @ checkpoint
           @ prose
               (Printf.sprintf
                  "Lane %s: %d candidates in the order the next cycle walks them; a turn \
                   that failed and deferred its input walks its remaining candidates \
                   instead."
                  (safe walk.lane_id)
                  (List.length forecast.Inspector.candidates)))
;;
