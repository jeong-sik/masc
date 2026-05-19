(** See [keeper_supervisor_self_preservation.mli] for the contract. *)

module StringMap = Map.Make (String)

type escape_state =
  { mutable last_dominant_cohort : string
  ; mutable consecutive_suppressions : int
  }

let escape_state = { last_dominant_cohort = ""; consecutive_suppressions = 0 }

(* 10 sweeps times the default 30s sweep interval gives a 5 minute probe cadence:
   long enough to avoid probing persistent systemic failures every cycle, short
   enough for transient cohorts to clear once the root condition is fixed. *)
let probe_after_n_suppressions = 10

(* Keep this below a majority so large-but-not-universal stale cohorts still use
   the circuit breaker/probe path. *)
let partial_stale_recovery_max_ratio = 0.50

let reset_for_test () =
  escape_state.last_dominant_cohort <- "";
  escape_state.consecutive_suppressions <- 0
;;

let group_by_failure_cohort to_restart =
  let insert_cohort acc (entry : Keeper_registry.registry_entry) msg =
    let key = Keeper_supervisor_types.cohort_key_of_reason entry.last_failure_reason in
    let prev = StringMap.find_opt key acc |> Option.value ~default:[] in
    StringMap.add key ((entry, msg) :: prev) acc
  in
  List.fold_left
    (fun acc ((entry, msg) : _ * string) -> insert_cohort acc entry msg)
    StringMap.empty
    to_restart
;;

let dominant_cohort cohorts =
  StringMap.fold
    (fun k v (best_k, best_v) ->
       if List.length v > List.length best_v then k, v else best_k, best_v)
    cohorts
    ("", [])
;;

let update_suppression_streak dominant_key =
  if String.equal escape_state.last_dominant_cohort dominant_key
  then
    escape_state.consecutive_suppressions
    <- escape_state.consecutive_suppressions + 1
  else (
    escape_state.last_dominant_cohort <- dominant_key;
    escape_state.consecutive_suppressions <- 1)
;;

let publish_suppression
      ~publish_lifecycle
      ~suppressed_count
      ~n_total
      ~dominant_key
      ~probe_entry
  =
  publish_lifecycle
    ~event:
      (Keeper_lifecycle_events.Custom_event
         { verb = Keeper_lifecycle_events.Self_preservation; phase = None })
    "supervisor"
    (Printf.sprintf
       "%d/%d suppressed, cohort=%s%s"
       suppressed_count
       n_total
       dominant_key
       (match probe_entry with
        | Some name -> Printf.sprintf ", probe=%s" name
        | None -> ""))
    ()
;;

let log_suppression ~ratio ~n_total ~dominant_key ~suppressed_count =
  if ratio >= 0.99
  then (
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_self_preservation_universal
      ~labels:[ "cohort", dominant_key ]
      ();
    Log.Keeper.error
      "self-preservation: UNIVERSAL suppression %d/%d (ratio=%.2f, cohort=%s, \
       streak=%d) -- auto-recovery is OFF until operator clears the shared failure \
       mode. Probe valve will allow one keeper through after %d consecutive \
       suppressions. See #10887 / #10765."
      suppressed_count
      n_total
      ratio
      dominant_key
      escape_state.consecutive_suppressions
      probe_after_n_suppressions)
  else
    Log.Keeper.warn
      "self-preservation: suppressing %d/%d restarts (ratio=%.2f, cohort=%s, \
       streak=%d)"
      suppressed_count
      n_total
      ratio
      dominant_key
      escape_state.consecutive_suppressions
;;

let apply ~keepers_dir ~publish_lifecycle ~total_keepers to_restart =
  let sp_ratio = Env_config.KeeperSupervisor.self_preservation_ratio in
  let sp_min = Env_config.KeeperSupervisor.self_preservation_min_candidates in
  let n_candidates = List.length to_restart in
  let n_total = max 1 total_keepers in
  let ratio = float_of_int n_candidates /. float_of_int n_total in
  if ratio > sp_ratio && n_candidates >= sp_min
  then (
    let dominant_key, dominant_entries =
      to_restart |> group_by_failure_cohort |> dominant_cohort
    in
    if List.length dominant_entries >= sp_min
    then (
      let dominant_count = List.length dominant_entries in
      let dominant_ratio = float_of_int dominant_count /. float_of_int n_total in
      if
        String.equal dominant_key Keeper_supervisor_types.stale_turn_timeout_cohort_key
        && dominant_ratio <= partial_stale_recovery_max_ratio
      then (
        reset_for_test ();
        Log.Keeper.warn
          "self-preservation: allowing partial stale_turn_timeout recovery cohort \
           through (dominant=%d/%d ratio_dominant=%.2f, overall_candidates=%d/%d \
           ratio_overall=%.2f)"
          dominant_count
          n_total
          dominant_ratio
          n_candidates
          n_total
          ratio;
        to_restart)
      else (
        update_suppression_streak dominant_key;
        let probe_due =
          escape_state.consecutive_suppressions >= probe_after_n_suppressions
        in
        let probe_entry =
          if probe_due
          then (
            match dominant_entries with
            | (entry, _) :: _ -> Some entry.Keeper_registry.name
            | [] -> None)
          else None
        in
        let suppressed_names =
          List.filter_map
            (fun ((entry : Keeper_registry.registry_entry), _) ->
               match probe_entry with
               | Some probe_name when String.equal entry.name probe_name -> None
               | _ -> Some entry.name)
            dominant_entries
        in
        let suppressed_count = List.length suppressed_names in
        (match probe_entry with
         | Some probe_name ->
           Log.Keeper.warn
             "self-preservation probe: allowing %s through after %d consecutive \
              same-cohort suppressions (ratio=%.2f, cohort=%s)"
             probe_name
             escape_state.consecutive_suppressions
             ratio
             dominant_key;
           escape_state.consecutive_suppressions <- 0
         | None -> log_suppression ~ratio ~n_total ~dominant_key ~suppressed_count);
        publish_suppression
          ~publish_lifecycle
          ~suppressed_count
          ~n_total
          ~dominant_key
          ~probe_entry;
        Keeper_crash_persistence.enqueue_sp_event
          ~keepers_dir
          ~ts:(Time_compat.now ())
          ~suppressed_count
          ~total:n_total
          ~ratio
          ~dominant_cohort:dominant_key;
        List.filter
          (fun ((entry : Keeper_registry.registry_entry), _) ->
             not (List.mem entry.name suppressed_names))
          to_restart))
    else (
      reset_for_test ();
      to_restart))
  else (
    reset_for_test ();
    to_restart)
;;
