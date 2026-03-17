(** Adaptive Thresholds — EMA-based threshold learning from handoff outcomes

    Learns optimal prepare/handoff context thresholds by observing handoff
    quality signals (completion rate, error count, emergency status).

    Safety bounds: 0.20 <= prepare < handoff <= 0.95, min gap 0.15
    Persistence: ~/.masc/adaptive_thresholds_{room}.json
    Fallback chain: adaptive (if enabled+available) -> env var -> defaults *)

(** Threshold pair *)
type thresholds = {
  prepare : float;  (** context usage % to start preparing *)
  handoff : float;  (** context usage % to trigger handoff *)
}

(** Persisted state for a room *)
type adaptive_state = {
  thresholds : thresholds;
  session_count : int;
  cumulative_delta : float;  (** total adjustment this session *)
  last_updated : string;     (** ISO 8601 timestamp *)
}

(** Default thresholds (matching Mitosis.Defaults) *)
let default_thresholds = { prepare = 0.50; handoff = 0.80 }

(** Safety bounds *)
let min_prepare = 0.20
let max_handoff = 0.95
let min_gap = 0.15

(** Clamp thresholds to safety bounds, maintaining min_gap *)
let clamp_thresholds (t : thresholds) : thresholds =
  (* First clamp individual bounds *)
  let handoff = Float.max (min_prepare +. min_gap) (Float.min max_handoff t.handoff) in
  let prepare = Float.max min_prepare (Float.min (handoff -. min_gap) t.prepare) in
  { prepare; handoff }

(** Get current ISO 8601 timestamp string *)
let iso_now () =
  let t = Time_compat.now () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (1900 + tm.Unix.tm_year) (1 + tm.Unix.tm_mon) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

(** Create initial adaptive state *)
let initial_state () = {
  thresholds = default_thresholds;
  session_count = 0;
  cumulative_delta = 0.0;
  last_updated = iso_now ();
}

(** Apply a handoff outcome to adapt thresholds.

    The handoff threshold receives the full (clamped) delta.
    The prepare threshold tracks proportionally, maintaining the gap.
    Both are clamped to safety bounds after adjustment. *)
let adapt (state : adaptive_state) (outcome : Handoff_quality.handoff_outcome) : adaptive_state =
  let raw_delta = Handoff_quality.compute_adjustment outcome in
  (* Clamp considering cumulative delta this session *)
  let available_positive = Handoff_quality.max_session_delta -. state.cumulative_delta in
  let available_negative = (-.Handoff_quality.max_session_delta) -. state.cumulative_delta in
  let clamped_delta =
    Handoff_quality.clamp_delta
      (Float.max available_negative (Float.min available_positive raw_delta))
  in
  (* Apply to handoff threshold *)
  let new_handoff = state.thresholds.handoff +. clamped_delta in
  (* Prepare tracks proportionally: maintain relative ratio *)
  let old_ratio =
    if state.thresholds.handoff > 0.0 then
      state.thresholds.prepare /. state.thresholds.handoff
    else 0.625 (* 0.50 / 0.80 default ratio *)
  in
  let new_prepare = new_handoff *. old_ratio in
  let new_thresholds = clamp_thresholds { prepare = new_prepare; handoff = new_handoff } in
  {
    thresholds = new_thresholds;
    session_count = state.session_count + 1;
    cumulative_delta = state.cumulative_delta +. clamped_delta;
    last_updated = iso_now ();
  }

(* ============================================================
   JSON Persistence
   ============================================================ *)

(** Serialize adaptive_state to JSON *)
let state_to_json (s : adaptive_state) : Yojson.Safe.t =
  `Assoc [
    ("prepare_threshold", `Float s.thresholds.prepare);
    ("handoff_threshold", `Float s.thresholds.handoff);
    ("session_count", `Int s.session_count);
    ("cumulative_delta", `Float s.cumulative_delta);
    ("last_updated", `String s.last_updated);
  ]

(** Deserialize adaptive_state from JSON *)
let state_of_json (json : Yojson.Safe.t) : adaptive_state option =
  match json with
  | `Assoc fields ->
    let get_float key =
      match List.assoc_opt key fields with
      | Some (`Float f) -> Some f
      | Some (`Int i) -> Some (float_of_int i)
      | _ -> None
    in
    let get_int key =
      match List.assoc_opt key fields with
      | Some (`Int i) -> Some i
      | _ -> None
    in
    let get_string key =
      match List.assoc_opt key fields with
      | Some (`String s) -> Some s
      | _ -> None
    in
    (match get_float "prepare_threshold",
           get_float "handoff_threshold",
           get_int "session_count",
           get_float "cumulative_delta",
           get_string "last_updated" with
     | Some p, Some h, Some sc, Some cd, Some lu ->
       Some {
         thresholds = clamp_thresholds { prepare = p; handoff = h };
         session_count = sc;
         cumulative_delta = cd;
         last_updated = lu;
       }
     | _ -> None)
  | _ -> None

(** Path to persistence file for a given room *)
let state_file_path ~(room : string) : string =
  let home = match Sys.getenv_opt "HOME" with
    | Some h -> h
    | None -> "/tmp"
  in
  let dir = Filename.concat home ".masc" in
  Filename.concat dir (Printf.sprintf "adaptive_thresholds_%s.json" room)

(** Save state to ~/.masc/adaptive_thresholds_{room}.json *)
let save_state ~(room : string) (state : adaptive_state) : unit =
  let path = state_file_path ~room in
  let dir = Filename.dirname path in
  Fs_compat.mkdir_p dir;
  let json_str = Yojson.Safe.pretty_to_string (state_to_json state) in
  Fs_compat.save_file path json_str

(** Load state from persistence, None if not found or invalid *)
let load_state ~(room : string) : adaptive_state option =
  let path = state_file_path ~room in
  if Sys.file_exists path then
    try
      let content = Fs_compat.load_file path in
      let json = Yojson.Safe.from_string content in
      state_of_json json
    with exn ->
      Log.Misc.warn "adaptive_thresholds: state load failed: %s" (Printexc.to_string exn);
      None
  else None

(* ============================================================
   Effective Thresholds — Fallback Chain
   ============================================================ *)

(** Get effective thresholds with fallback chain:
    1. Adaptive (if enabled AND state file exists for room)
    2. Environment variables MASC_MITOSIS_PREPARE_THRESHOLD / MASC_MITOSIS_HANDOFF_THRESHOLD
    3. Module defaults (0.50, 0.80)
    4. Conservative hardcoded (0.40, 0.75) — unreachable, kept as safety net *)
let get_effective_thresholds ~(enabled : bool) ~(room : string) : thresholds =
  (* 1. Adaptive thresholds *)
  if enabled then
    match load_state ~room with
    | Some state -> state.thresholds
    | None -> (* Fall through to env vars *)
      (* 2. Environment variables *)
      let env_prepare = Sys.getenv_opt "MASC_MITOSIS_PREPARE_THRESHOLD" in
      let env_handoff = Sys.getenv_opt "MASC_MITOSIS_HANDOFF_THRESHOLD" in
      (match env_prepare, env_handoff with
       | Some p, Some h ->
         (try clamp_thresholds { prepare = float_of_string p; handoff = float_of_string h }
          with Failure _ -> default_thresholds)
       | _ -> default_thresholds)
  else
    (* Not enabled: check env vars, then defaults *)
    let env_prepare = Sys.getenv_opt "MASC_MITOSIS_PREPARE_THRESHOLD" in
    let env_handoff = Sys.getenv_opt "MASC_MITOSIS_HANDOFF_THRESHOLD" in
    match env_prepare, env_handoff with
    | Some p, Some h ->
      (try clamp_thresholds { prepare = float_of_string p; handoff = float_of_string h }
       with Failure _ -> default_thresholds)
    | _ -> default_thresholds
