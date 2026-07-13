(** masc-trace — print receipts matching a (keeper, turn_id) pair.

    This is the foundation of the Step 10 turn-tracing CLI from the
    bloodflow restoration plan.  The first cut intentionally reads
    only execution-receipts JSONL since that's the path that already
    populates [turn_count] (post-Step 0a it carries the structured
    [keeper_turn_id] for silent skip and runtime error
    paths too).

    Follow-up stacks will widen the source set:
      - .masc/tool_calls/<YYYY-MM>/<DD>.jsonl
      - .masc/logs/system_log_<date>.jsonl (post 0a-2 caller adoption)
      - .masc/traces/<keeper>/<trace_id>/
      - .masc/keepers/<keeper>/runtime-manifests/<trace_id>.jsonl

    Usage:  masc-trace <base-path> <keeper> <turn_id>
    Example: masc-trace ~/me nick0cave 5
*)

let usage_and_exit () =
  prerr_endline "Usage: masc-trace <base-path> <keeper> <turn_id>";
  exit 2

let read_lines path =
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    let rec loop acc =
      match input_line ic with
      | line -> loop (line :: acc)
      | exception End_of_file -> List.rev acc
    in
    match loop [] with
    | lines ->
      close_in_noerr ic;
      lines
    | exception exn ->
      close_in_noerr ic;
      raise exn

let int_field json key =
  match Yojson.Safe.Util.member key json with `Int n -> Some n | _ -> None

let string_field json key =
  match Yojson.Safe.Util.member key json with
  | `String s -> Some s
  | _ -> None

let decision_int_field json key =
  Yojson.Safe.Util.member "decision" json |> fun decision ->
  int_field decision key

let decision_string_field json key =
  Yojson.Safe.Util.member "decision" json |> fun decision ->
  string_field decision key

let masc_root ~base_path = Config_dir_resolver.masc_root ~base_path

let receipts_dir ~base_path ~keeper =
  List.fold_left Filename.concat (masc_root ~base_path)
    [ "keepers"; keeper; "execution-receipts" ]

let runtime_manifests_dir ~base_path ~keeper =
  List.fold_left Filename.concat (masc_root ~base_path)
    [ "keepers"; keeper; "runtime-manifests" ]

let logs_dir ~base_path =
  List.fold_left Filename.concat (masc_root ~base_path) [ "logs" ]

let tool_calls_dir ~base_path =
  List.fold_left Filename.concat (masc_root ~base_path) [ "tool_calls" ]

(** Naive substring check — avoids pulling in [Str] for one call. *)
let contains_substring s sub =
  let lens = String.length s in
  let lensub = String.length sub in
  if lensub = 0 then true
  else if lensub > lens then false
  else
    let rec loop i =
      if i > lens - lensub then false
      else if String.sub s i lensub = sub then true
      else loop (i + 1)
    in
    loop 0

let dump_receipts ~base_path ~keeper ~turn_id =
  let dir = receipts_dir ~base_path ~keeper in
  if not (Sys.file_exists dir) then begin
    Printf.eprintf "[masc-trace] no receipts dir: %s\n" dir;
    ()
  end
  else
    let files =
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".jsonl")
      |> List.sort compare
    in
    let matches =
      List.concat_map
        (fun f ->
          let path = Filename.concat dir f in
          read_lines path
          |> List.filter_map (fun line ->
                 try
                   let json = Yojson.Safe.from_string line in
                   if int_field json "turn_count" = Some turn_id then
                     Some (f, json)
                   else None
                 with exn ->
                   Printf.eprintf
                     "[masc-trace] warning: skipping malformed line in %s: %s\n"
                     f (Printexc.to_string exn);
                   None))
        files
    in
    if matches = [] then
      Printf.eprintf
        "[masc-trace] no receipt found for keeper=%s turn_id=%d\n"
        keeper turn_id
    else
      List.iter
        (fun (f, json) ->
          let outcome =
            Option.value (string_field json "outcome") ~default:"-"
          in
          let reason =
            Option.value
              (string_field json "terminal_reason_code")
              ~default:"-"
          in
          let runtime =
            Option.value (string_field json "runtime_id") ~default:"-"
          in
          let ended =
            Option.value (string_field json "ended_at") ~default:"-"
          in
          Printf.printf
            "%s [receipt %s] runtime=%s outcome=%s reason=%s\n"
            ended f runtime outcome reason)
        matches

(** Scan [.masc/keepers/<keeper>/runtime-manifests/<trace_id>.jsonl]
    for manifest rows matching [keeper_turn_id].  This is the causal
    chain source: phase gate, runtime routing, provider attempts, context
    checkpoints, receipts, and terminal outcome. *)
let dump_runtime_manifests ~base_path ~keeper ~turn_id =
  let dir = runtime_manifests_dir ~base_path ~keeper in
  if not (Sys.file_exists dir) then
    Printf.eprintf "[masc-trace] no runtime-manifests dir: %s\n" dir
  else
    let files =
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".jsonl")
      |> List.sort compare
    in
    let matches =
      List.concat_map
        (fun f ->
          let path = Filename.concat dir f in
          read_lines path
          |> List.filter_map (fun line ->
                 try
                   let json = Yojson.Safe.from_string line in
                   let keeper_match =
                     string_field json "keeper_name" = Some keeper
                   in
                   let turn_match =
                     int_field json "keeper_turn_id" = Some turn_id
                   in
                   if keeper_match && turn_match then Some (f, json)
                   else None
                 with exn ->
                   Printf.eprintf
                     "[masc-trace] warning: skipping malformed line in %s: %s\n"
                     f (Printexc.to_string exn);
                   None))
        files
    in
    if matches = [] then
      Printf.eprintf
        "[masc-trace] no runtime manifest found for keeper=%s turn_id=%d\n"
        keeper turn_id
    else
      let json_rows = List.map snd matches in
      let count_event event =
        json_rows
        |> List.fold_left
             (fun count json ->
               if string_field json "event" = Some event then count + 1
               else count)
             0
      in
      let max_oas_turn_count =
        json_rows
        |> List.filter_map (fun json -> int_field json "oas_turn_count")
        |> List.fold_left
             (fun acc value ->
               match acc with
               | None -> Some value
               | Some current -> Some (max current value))
             None
      in
      let event_bus_rows =
        json_rows
        |> List.filter (fun json ->
             string_field json "event" = Some "event_bus_correlated")
      in
      let event_bus_correlation =
        match
          event_bus_rows
          |> List.filter_map (fun json ->
               decision_string_field json "correlation_id")
        with
        | first :: _ -> first
        | [] -> "-"
      in
      let sum_event_bus_int key =
        event_bus_rows
        |> List.fold_left
             (fun total json ->
               total + Option.value (decision_int_field json key) ~default:0)
             0
      in
      Printf.printf
        "=== turn identity === keeper=%s keeper_turn_id=%d manifest_rows=%d \
         max_oas_turn_count=%s provider_attempts=%d/%d provider_lanes=%d \
         checkpoints_saved=%d receipts_appended=%d turn_finished=%d \
         event_bus=%d correlation_id=%s compaction=%d/%d memory=%d/%d\n"
        keeper turn_id (List.length matches)
        (match max_oas_turn_count with
         | None -> "-"
         | Some value -> string_of_int value)
        (count_event "provider_attempt_started")
        (count_event "provider_attempt_finished")
        (count_event "provider_lane_resolved")
        (count_event "checkpoint_saved")
        (count_event "receipt_appended")
        (count_event "turn_finished")
        (List.length event_bus_rows)
        event_bus_correlation
        (sum_event_bus_int "context_compact_started_count")
        (sum_event_bus_int "context_compacted_count")
        (count_event "memory_injected")
        (count_event "memory_flushed");
      List.iter
        (fun (f, json) ->
          let ts = Option.value (string_field json "ts") ~default:"-" in
          let event = Option.value (string_field json "event") ~default:"-" in
          let status = Option.value (string_field json "status") ~default:"-" in
          let runtime =
            Option.value (string_field json "runtime_id") ~default:"-"
          in
          let decision =
            match Yojson.Safe.Util.member "decision" json with
            | `Null -> "{}"
            | decision_json -> Yojson.Safe.to_string decision_json
          in
          Printf.printf
            "%s [manifest %s] event=%s status=%s runtime=%s decision=%s\n"
            ts f event status runtime decision)
        matches

(** Scan [.masc/logs/system_log_*.jsonl] for [\[fsm:transition\]]
    lines that match the given (keeper, turn_id).

    Step 4b/c/d/g/i/j wired [Keeper_turn_fsm.emit_transition] at
    every state transition in [run_keeper_cycle].  This widens
    the [bin/masc-trace] source set so the timeline shows the
    typed FSM steps next to the receipt rows. *)
let dump_fsm_transitions ~base_path ~keeper ~turn_id =
  let dir = logs_dir ~base_path in
  if not (Sys.file_exists dir) then ()
  else
    let files =
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun f ->
             Filename.check_suffix f ".jsonl"
             && String.length f >= String.length "system_log_"
             && String.sub f 0 (String.length "system_log_")
                = "system_log_")
      |> List.sort compare
    in
    let matches =
      List.concat_map
        (fun f ->
          let path = Filename.concat dir f in
          read_lines path
          |> List.filter_map (fun line ->
                 try
                   let json = Yojson.Safe.from_string line in
                   let keeper_match =
                     string_field json "keeper_name" = Some keeper
                   in
                   let turn_match =
                     int_field json "turn_id" = Some turn_id
                   in
                   let msg =
                     Option.value
                       (string_field json "message")
                       ~default:""
                   in
                   let is_fsm =
                     contains_substring msg "[fsm:transition]"
                   in
                   if keeper_match && turn_match && is_fsm then
                     Some json
                   else None
                 with exn ->
                   Printf.eprintf
                     "[masc-trace] warning: skipping malformed line in %s: %s\n"
                     f (Printexc.to_string exn);
                   None))
        files
    in
    if matches = [] then
      Printf.eprintf
        "[masc-trace] no [fsm:transition] lines for keeper=%s \
         turn_id=%d\n"
        keeper turn_id
    else
      List.iter
        (fun json ->
          let ts =
            Option.value (string_field json "ts") ~default:"-"
          in
          let msg =
            Option.value
              (string_field json "message")
              ~default:"-"
          in
          Printf.printf "%s [fsm] %s\n" ts msg)
        matches;
    (* Path summary: extract the [to_state] from each [fsm:transition]
       line and join with arrows.  An operator scanning for "did this
       turn reach done?" gets the answer in one line without scrolling
       through the per-row trail above. *)
    let extract_to_state msg =
      let needle = "-> " in
      let lens = String.length msg in
      let lensub = String.length needle in
      let rec find i =
        if i > lens - lensub then None
        else if String.sub msg i lensub = needle then
          let rest = String.sub msg (i + lensub) (lens - i - lensub) in
          Some (String.trim rest)
        else find (i + 1)
      in
      find 0
    in
    if matches <> [] then begin
      (* Pair each transition's [to_state] with its [ts] field so the
         summary line carries timestamps the operator can eyeball for
         per-state duration.  No OCaml-side mutable accumulation: the
         emit calls are stateless, and any duration derivation is a
         pure projection of the already-emitted [ts] timeline.  External
         metric queries and this CLI are the right boundary for time-series math. *)
      let state_with_ts =
        List.filter_map
          (fun json ->
            let msg =
              string_field json "message" |> Option.value ~default:""
            in
            let ts =
              string_field json "ts" |> Option.value ~default:"-"
            in
            extract_to_state msg
            |> Option.map (fun s -> (s, ts)))
          matches
      in
      if state_with_ts <> [] then
        let render (state, ts) = Printf.sprintf "%s @%s" state ts in
        Printf.printf "=== fsm path === %s -> %s\n" keeper
          (String.concat " -> "
             (List.map render state_with_ts))
    end

(** Scan [.masc/tool_calls/<YYYY-MM>/<DD>.jsonl] for tool call
    rows whose [keeper] = our keeper and
    [runtime_contract.keeper_turn_id] = our turn_id.

    Schema (post Step 0a):
    - top-level [keeper], [tool], [success], [duration_ms], [ts] (epoch float)
    - nested [runtime_contract.keeper_turn_id] (int option)

    Records pre Step 0a have [keeper_turn_id = null]; those are
    skipped silently because there's nothing to correlate them
    with. *)
let dump_tool_calls ~base_path ~keeper ~turn_id =
  let root = tool_calls_dir ~base_path in
  if not (Sys.file_exists root) then ()
  else
    (* tool_calls/YYYY-MM/DD.jsonl — recurse one level. *)
    let month_dirs =
      Sys.readdir root
      |> Array.to_list
      |> List.filter (fun d ->
             Sys.is_directory (Filename.concat root d))
      |> List.sort compare
    in
    let files =
      List.concat_map
        (fun mdir ->
          let mpath = Filename.concat root mdir in
          Sys.readdir mpath
          |> Array.to_list
          |> List.filter (fun f -> Filename.check_suffix f ".jsonl")
          |> List.sort compare
          |> List.map (fun f -> Filename.concat mpath f))
        month_dirs
    in
    let runtime_contract_int_field json key =
      match Yojson.Safe.Util.member "runtime_contract" json with
      | `Assoc _ as rc -> int_field rc key
      | _ -> None
    in
    let matches =
      List.concat_map
        (fun path ->
          read_lines path
          |> List.filter_map (fun line ->
                 try
                   let json = Yojson.Safe.from_string line in
                   let keeper_match =
                     string_field json "keeper" = Some keeper
                   in
                   let turn_match =
                     runtime_contract_int_field json
                       "keeper_turn_id"
                     = Some turn_id
                   in
                   if keeper_match && turn_match then Some json
                   else None
                 with exn ->
                   Printf.eprintf
                     "[masc-trace] warning: skipping malformed line in %s: %s\n"
                     (Filename.basename path)
                       (Printexc.to_string exn);
                   None))
        files
    in
    if matches = [] then
      Printf.eprintf
        "[masc-trace] no tool_calls for keeper=%s turn_id=%d \
         (note: pre-Step-0a rows have keeper_turn_id=null and \
         are unreachable by id)\n"
        keeper turn_id
    else
      List.iter
        (fun json ->
          let tool =
            Option.value (string_field json "tool") ~default:"-"
          in
          let success =
            match Yojson.Safe.Util.member "success" json with
            | `Bool b -> if b then "ok" else "fail"
            | _ -> "-"
          in
          let duration_ms =
            match Yojson.Safe.Util.member "duration_ms" json with
            | `Float f -> Printf.sprintf "%.0f" f
            | `Int n -> string_of_int n
            | _ -> "-"
          in
          let ts =
            match Yojson.Safe.Util.member "ts" json with
            | `Float f -> Printf.sprintf "%.3f" f
            | `Int n -> string_of_int n
            | _ -> "-"
          in
          Printf.printf
            "%s [tool %s] %s duration_ms=%s\n"
            ts tool success duration_ms)
        matches

let () =
  match Array.to_list Sys.argv with
  | _ :: base_path :: keeper :: turn_id_str :: _ -> (
      match int_of_string_opt turn_id_str with
      | Some turn_id ->
          dump_receipts ~base_path ~keeper ~turn_id;
          dump_runtime_manifests ~base_path ~keeper ~turn_id;
          dump_fsm_transitions ~base_path ~keeper ~turn_id;
          dump_tool_calls ~base_path ~keeper ~turn_id
      | None ->
          prerr_endline "turn_id must be an integer";
          usage_and_exit ())
  | _ -> usage_and_exit ()
