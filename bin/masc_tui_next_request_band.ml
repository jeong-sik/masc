(* The NEXT REQUEST band of the context inspector: the turn's own arithmetic
   run forward by the server (window × density, less the fixed parts and the
   pinned blocks, cut on the durable history), drawn in tokens. A candidate
   with a measured density reads at that density, the exact ratio for its
   runtime; one without reads at the tab's scale. *)

module Inspector = Masc_tui_context_inspector
open Masc_tui_ansi

let signed_tokens n =
  if n < 0 then "\xe2\x88\x92" ^ Inspector.format_tokens (-n)
  else Inspector.format_tokens n
;;

let candidate_lines ~prose ~fact ~safe ~scale
    (candidate : Inspector.forecast_candidate) =
  let tokens_of_bytes =
    match candidate.capacity with
    | Some (Inspector.Capacity_measured { density; _ }) ->
        fun bytes ->
          int_of_float
            (Float.round
               (float bytes *. float density.input_tokens
                /. float density.measured_bytes))
    | Some Inspector.Capacity_unmeasured | None ->
        Masc_tui_token_scale.estimate scale
  in
  let approx bytes = "\xe2\x89\x88" ^ signed_tokens (tokens_of_bytes bytes) in
  let head =
    match candidate.window with
    | Inspector.Window_refused reason ->
        [ Theme.bad () ^ "  " ^ safe candidate.runtime_id ^ "  ·  " ^ safe reason
          ^ Ansi.reset
        ]
    | Inspector.Window_not_applicable reason ->
        fact (safe candidate.runtime_id) @ prose (safe reason ^ ".")
    | Inspector.Window_declared { window_tokens; source } ->
        fact
          (Printf.sprintf "%s  ·  window %s tok %s" (safe candidate.runtime_id)
             (Inspector.format_tokens window_tokens) (safe source))
  in
  let capacity_line =
    match candidate.capacity with
    | None -> []
    | Some Inspector.Capacity_unmeasured ->
        prose
          "No response on this runtime since the server started, so no \
           density: the next request sends the newest atom only, and its \
           usage sets the density."
    | Some (Inspector.Capacity_measured { capacity_bytes; density }) ->
        fact
          (Printf.sprintf "capacity %s tok at this runtime's %.2f bytes per token%s"
             (approx capacity_bytes)
             (float density.measured_bytes /. float density.input_tokens)
             (match candidate.request_cap_bytes with
              | Some cap ->
                  Printf.sprintf "  ·  provider accepts up to %s tok" (approx cap)
              | None -> ""))
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
    match candidate.parts, candidate.capacity with
    | Error reason, _ ->
        prose
          ("Fixed parts unknown, so no cut was computed: " ^ safe reason ^ ".")
    | Ok parts, Some (Inspector.Capacity_measured { capacity_bytes; _ }) ->
        fact
          (Printf.sprintf
             "fixed parts %s tok (turn #%d) + pinned %s tok %s  \
              \xe2\x86\x92  history room %s tok"
             (approx parts.reserved_bytes) parts.reserved_measured_on_turn
             (approx parts.pinned_bytes) (pinned_provenance parts)
             (approx (capacity_bytes - parts.reserved_bytes - parts.pinned_bytes)))
    | Ok parts, (Some Inspector.Capacity_unmeasured | None) ->
        fact
          (Printf.sprintf "fixed parts %s tok (turn #%d) + pinned %s tok %s"
             (approx parts.reserved_bytes) parts.reserved_measured_on_turn
             (approx parts.pinned_bytes) (pinned_provenance parts))
  in
  let cut_line =
    match candidate.cut with
    | None -> []
    | Some (Inspector.Forecast_newest_atom_only { transmitted_bytes }) ->
        fact
          (Printf.sprintf "1 of %d kept atoms would go (%s tok)" candidate.history_atoms
             (approx transmitted_bytes))
    | Some (Inspector.Forecast_cut { kept_atoms; transmitted_bytes; fit }) ->
        fact
          (Printf.sprintf "%d of %d kept atoms would go (%s tok)  ·  %s" kept_atoms
             candidate.history_atoms (approx transmitted_bytes)
             (match fit with
              | Inspector.Within_target -> "within the window"
              | Inspector.Overrun { by_bytes; cause = Inspector.Fixed_parts_exceed_target }
                ->
                  Printf.sprintf
                    "over the window by %s tok: the fixed parts alone exceed it"
                    (approx by_bytes)
              | Inspector.Overrun { by_bytes; cause = Inspector.Newest_atom_exceeds_target }
                ->
                  Printf.sprintf
                    "over the window by %s tok: the newest atom alone exceeds it"
                    (approx by_bytes)))
  in
  head @ capacity_line @ parts_line @ cut_line
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
