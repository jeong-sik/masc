(* See cascade_attempt_liveness_config.mli for documentation.

   RFC-0022 PR-2/4 §2 — tri-state env flag + living budget map. *)

type mode =
  | Off
  | Observe
  | Enforce

let mode_label = function
  | Off -> "off"
  | Observe -> "observe"
  | Enforce -> "enforce"

let env_var_name = "MASC_CASCADE_ATTEMPT_LIVENESS"

let parse_mode raw =
  match String.lowercase_ascii (String.trim raw) with
  | "off" | "0" | "false" | "disabled" -> Off
  | "enforce" | "kill" | "on_kill" -> Enforce
  | "" | "observe" | "default" | "1" | "true" | "shadow" -> Observe
  | _ -> Observe (* unknown values default to Observe — never silently Off *)

(* Cached after first read. Mirrors Keeper_admission_glue.use_new_admission. *)
let mode_cache : mode option ref = ref None

let current_mode () =
  match !mode_cache with
  | Some m -> m
  | None ->
      let m =
        match Sys.getenv_opt env_var_name with
        | None -> Enforce
        | Some raw -> parse_mode raw
      in
      mode_cache := Some m;
      m

let reset_cache_for_test () = mode_cache := None

type success_sample =
  { ttft_ms : float
  ; max_inter_chunk_ms : float
  ; wall_ms : float
  }

type budget_source =
  | Bootstrap
  | Observed_success of { samples : int }

type resolved_budget =
  { budget : Cascade_attempt_liveness.budget
  ; source : budget_source
  }

let budget_source_label = function
  | Bootstrap -> "bootstrap"
  | Observed_success _ -> "observed_success"

let success_history : (string, success_sample list) Hashtbl.t = Hashtbl.create 64
let success_history_mu = Stdlib.Mutex.create ()

let with_success_history_lock f =
  Stdlib.Mutex.lock success_history_mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock success_history_mu) f

let success_history_limit =
  match Sys.getenv_opt "MASC_CASCADE_LIVENESS_SUCCESS_HISTORY_SIZE" with
  | None | Some "" -> 32
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | Some n -> max 1 (min 256 n)
     | None -> 32)

let finite_non_negative v = Float.is_finite v && Float.compare v 0.0 >= 0

let valid_sample (s : success_sample) =
  finite_non_negative s.ttft_ms
  && finite_non_negative s.max_inter_chunk_ms
  && finite_non_negative s.wall_ms

let take limit values =
  let rec loop n acc = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | x :: rest -> loop (n - 1) (x :: acc) rest
  in
  loop limit [] values

let record_success_sample ~candidate_key (sample : success_sample) =
  let key = String.trim candidate_key in
  if key = "" || not (valid_sample sample) then ()
  else
    with_success_history_lock (fun () ->
        let current =
          match Hashtbl.find_opt success_history key with
          | Some samples -> samples
          | None -> []
        in
        Hashtbl.replace success_history key (take success_history_limit (sample :: current)))

let reset_success_history_for_test () =
  with_success_history_lock (fun () -> Hashtbl.clear success_history)

let success_sample_count_for_test ~candidate_key =
  let key = String.trim candidate_key in
  with_success_history_lock (fun () ->
      match Hashtbl.find_opt success_history key with
      | Some samples -> List.length samples
      | None -> 0)

let percentile p values =
  match List.sort Float.compare values with
  | [] -> None
  | sorted ->
    let len = List.length sorted in
    let raw_idx = int_of_float (ceil (p *. float_of_int len)) - 1 in
    let idx = max 0 (min (len - 1) raw_idx) in
    List.nth_opt sorted idx

let seconds_of_ms ms = ms /. 1000.0

let clamp_float ~floor ~ceiling v =
  Float.max floor (Float.min ceiling v)

let tuned_seconds ~floor ~ceiling ~multiplier ~add seconds =
  clamp_float ~floor ~ceiling ((seconds *. multiplier) +. add)

let budget_of_samples samples =
  let p95 field = percentile 0.95 (List.map field samples) in
  match p95 (fun s -> s.ttft_ms), p95 (fun s -> s.max_inter_chunk_ms),
        p95 (fun s -> s.wall_ms) with
  | Some ttft_ms, Some inter_ms, Some wall_ms ->
    let ttft_max =
      tuned_seconds
        ~floor:30.0
        ~ceiling:900.0
        ~multiplier:1.5
        ~add:5.0
        (seconds_of_ms ttft_ms)
    in
    let inter_chunk_max =
      tuned_seconds
        ~floor:20.0
        ~ceiling:240.0
        ~multiplier:2.0
        ~add:5.0
        (seconds_of_ms inter_ms)
    in
    let observed_wall =
      tuned_seconds
        ~floor:180.0
        ~ceiling:3600.0
        ~multiplier:1.4
        ~add:30.0
        (seconds_of_ms wall_ms)
    in
    let attempt_wall_max =
      Float.max observed_wall (ttft_max +. inter_chunk_max)
    in
    { Cascade_attempt_liveness.ttft_max = ttft_max
    ; inter_chunk_max
    ; attempt_wall_max
    }
  | _ -> Cascade_attempt_liveness.bootstrap

let budget_for_candidate ~candidate_key =
  let key = String.trim candidate_key in
  let samples =
    if key = "" then []
    else
      with_success_history_lock (fun () ->
          match Hashtbl.find_opt success_history key with
          | Some samples -> samples
          | None -> [])
  in
  match samples with
  | [] -> { budget = Cascade_attempt_liveness.bootstrap; source = Bootstrap }
  | samples ->
    { budget = budget_of_samples samples
    ; source = Observed_success { samples = List.length samples }
    }

(* RFC-0022 §1 — see .mli for contract. *)
let outer_wall_for_attempt
    ~mode ~observer_attached ~per_provider_timeout_s ~candidate_key =
  match mode, observer_attached with
  | Enforce, true -> None
  | _, true ->
      let resolved = budget_for_candidate ~candidate_key in
      let budget_wall =
        resolved.budget.Cascade_attempt_liveness.attempt_wall_max
      in
      Option.map
        (fun t -> Float.max t budget_wall)
        per_provider_timeout_s
  | _, false -> per_provider_timeout_s
