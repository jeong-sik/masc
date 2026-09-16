(* The NEXT REQUEST band of the context inspector: the turn's own composition
   run forward by the server (the carried range from the pair's front over
   the durable history), drawn in tokens at the tab's scale. What the marks
   are read against is the provider's count, so it is shown as counted. *)

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
  | Inspector.Carried_fit_to_request_cap ->
      "no front to start from: the newest suffix the request cap admits"
  | Inspector.Carried_whole_history -> "no front to start from and no cap: the whole history"
;;

let candidate_lines ~prose ~fact ~safe ~scale
    (candidate : Inspector.forecast_candidate) =
  let tokens_of_bytes = Masc_tui_token_scale.estimate scale in
  let approx bytes = "\xe2\x89\x88" ^ signed_tokens (tokens_of_bytes bytes) in
  let cap_suffix =
    match candidate.request_cap_bytes with
    | Some cap -> Printf.sprintf "  \xc2\xb7  provider accepts up to %s tok" (approx cap)
    | None -> ""
  in
  let head =
    match candidate.lane with
    | Inspector.Lane_not_applicable reason ->
        fact (safe candidate.runtime_id) @ prose (safe reason ^ ".")
    | Inspector.Lane_agent_core ->
        (match candidate.marks with
         | Some marks ->
             fact
               (Printf.sprintf "%s  \xc2\xb7  marks %s / %s tok%s" (safe candidate.runtime_id)
                  (Inspector.format_tokens marks.high_water_tokens)
                  (Inspector.format_tokens marks.low_water_tokens)
                  cap_suffix)
         | None ->
             fact
               (Printf.sprintf "%s  \xc2\xb7  no marks declared: only a refusal moves the front%s"
                  (safe candidate.runtime_id) cap_suffix))
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
  head @ parts_line @ carried_lines
;;

let lines ~prose ~fact ~safe ~scale
    (forecast : (Inspector.forecast, string) result) =
  match forecast with
  | Error detail ->
      [ Theme.bad () ^ "  Next request not forecast: " ^ safe detail ^ Ansi.reset ]
  | Ok forecast ->
      List.concat_map
        (candidate_lines ~prose ~fact ~safe ~scale)
        forecast.Inspector.candidates
      @ prose
          (Printf.sprintf
             "%d messages in the checkpoint; the wake line adds %d bytes as the \
              newest atom. Only the bound runtime is forecast."
             forecast.Inspector.checkpoint_messages forecast.Inspector.wake_line_bytes)
;;
