(** Keeper_tool_affinity — History-based tool pre-population.

    Reads trajectory JSONL and computes an affinity score for each tool.
    Tools with high scores are pre-populated into the per-session
    Keeper_discovered_tools so they are visible from turn 0.

    Scoring:  score = call_count * success_rate * recency_weight
      - success_rate = success_count / call_count  (threshold >= 0.3)
      - recency_weight = exp(-lambda * age_hours)  (lambda = 0.01, ~3-day half-life)

    @since 2.251.0
    @see <https://github.com/jeong-sik/masc-mcp/issues/5566> *)

(* ================================================================ *)
(* Configuration                                                     *)
(* ================================================================ *)

let default_max_k = 5
let default_lookback_days = 7
let min_success_rate = 0.3
let recency_lambda = 0.01

(* Empty/whitespace-only env values count as unset: OCaml stdlib has no
   portable [Unix.unsetenv] before 4.12, and the codebase convention is
   [Unix.putenv name ""] to clear a var. Without the trim guard,
   [Some ""] would be distinguishable from [None] at the reader level
   even though the intent is identical. *)
let clamped_env_int ?(getenv = Sys.getenv_opt) ~name ~min_val ~max_val ~default () =
  match getenv name with
  | Some s when String.trim s <> "" ->
    max min_val
      (min max_val
         (Safe_ops.int_of_string_with_default ~default s))
  | Some _ | None -> default

(* Clamp bounds: max_k cap of 20 keeps the discovered-tools window
   bounded for small-context models; lookback cap of 30 days matches
   the trajectory retention window. *)
let configured_max_k ?(getenv = Sys.getenv_opt) () =
  clamped_env_int ~getenv
    ~name:"MASC_KEEPER_TOOL_AFFINITY_K"
    ~min_val:0 ~max_val:20 ~default:default_max_k ()

let configured_lookback_days ?(getenv = Sys.getenv_opt) () =
  clamped_env_int ~getenv
    ~name:"MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS"
    ~min_val:1 ~max_val:30 ~default:default_lookback_days ()

(* ================================================================ *)
(* Types                                                             *)
(* ================================================================ *)

type affinity_entry = {
  tool_name : string;
  score : float;
  call_count : int;
  success_rate : float;
}

(* ================================================================ *)
(* ISO8601 timestamp parser (minimal)                                *)
(* ================================================================ *)

(** Compute the local→UTC offset in seconds.
    Cached once per process to avoid repeated syscalls. *)
let utc_offset_sec : float =
  let t = Unix.gettimeofday () in
  let utc_tm = Unix.gmtime t in
  let (local_as_utc, _) = Unix.mktime utc_tm in
  t -. local_as_utc

(** Parse "YYYY-MM-DDTHH:MM:SSZ" to Unix timestamp (UTC).
    [Unix.mktime] interprets as local time, so we subtract [utc_offset_sec]
    to convert to true UTC.  Returns [None] on parse failure. *)
let unix_of_iso8601 (s : string) : float option =
  try
    Scanf.sscanf s "%d-%d-%dT%d:%d:%d"
      (fun year mon day hour minute sec ->
        let tm : Unix.tm = {
          tm_sec = sec; tm_min = minute; tm_hour = hour;
          tm_mday = day; tm_mon = mon - 1; tm_year = year - 1900;
          tm_wday = 0; tm_yday = 0; tm_isdst = false;
        } in
        let (ts, _) = Unix.mktime tm in
        Some (ts -. utc_offset_sec))
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None

(* ================================================================ *)
(* Scoring                                                           *)
(* ================================================================ *)

let compute_affinity ~(tool_stats : Trajectory.tool_stat list)
    ~(now : float) ~(max_k : int) : affinity_entry list =
  if max_k <= 0 then []
  else
    tool_stats
    |> List.filter_map (fun (s : Trajectory.tool_stat) ->
      let success_rate =
        if s.call_count > 0
        then float_of_int s.success_count /. float_of_int s.call_count
        else 0.0
      in
      if success_rate < min_success_rate then None
      else
        let age_hours =
          match unix_of_iso8601 s.last_used_at with
          | Some last_ts ->
            let h = (now -. last_ts) /. 3600.0 in
            Float.max 0.0 h
          | None -> 168.0  (* 7 days fallback *)
        in
        let recency_weight = exp (-. recency_lambda *. age_hours) in
        let score =
          float_of_int s.call_count *. success_rate *. recency_weight
        in
        Some { tool_name = s.name; score; call_count = s.call_count;
               success_rate })
    |> List.sort (fun a b -> Float.compare b.score a.score)
    |> List.take max_k

(* ================================================================ *)
(* Main entry point                                                  *)
(* ================================================================ *)

let pre_populate_from_history
    ~(masc_root : string) ~(keeper_name : string)
    ~(allowed_tool_names : string list) ~(core_tool_names : string list)
    ~(discovered : Keeper_discovered_tools.t) ~(max_k : int)
    : affinity_entry list =
  if max_k <= 0 then []
  else
    let now = Unix.gettimeofday () in
    let lookback_days = configured_lookback_days () in
    let since = now -. Masc_time_constants.days_to_seconds lookback_days in
    let entries =
      Trajectory.read_entries_since ~masc_root ~keeper_name ~since
    in
    match entries with
    | [] -> []
    | _ ->
      let tool_stats = Trajectory.aggregate_tool_stats entries in
      let allowed_set = Hashtbl.create (List.length allowed_tool_names) in
      List.iter (fun n -> Hashtbl.replace allowed_set n ()) allowed_tool_names;
      let core_set = Hashtbl.create (List.length core_tool_names) in
      List.iter (fun n -> Hashtbl.replace core_set n ()) core_tool_names;
      let filtered_stats =
        tool_stats
        |> List.filter (fun (s : Trajectory.tool_stat) ->
          Hashtbl.mem allowed_set s.name
          && not (Hashtbl.mem core_set s.name))
      in
      let affinity = compute_affinity ~tool_stats:filtered_stats ~now ~max_k in
      let names = List.map (fun a -> a.tool_name) affinity in
      if names <> [] then
        Keeper_discovered_tools.add discovered ~turn:0 ~names;
      affinity
