(* The compaction summarizer resolves this lane by name; it must exist in
   every published registry for manual/provider-overflow compaction to run. *)
let compaction_exact_lane_id = "compaction_exact"

(* Upgraded workspaces keep their operator-owned runtime.toml, which predates
   [runtime.exact_output_lanes]. Without a backfill a published registry would
   carry zero lanes and every compaction would fail at execution with
   [Exact_target_selection_failed]. The seed declaration comes from the
   binary-embedded seed config so repo config and backfill share one source;
   operator declarations always win. *)
let seed_lane_declarations () =
  match Embedded_config.read "runtime.toml" with
  | None ->
    Log.Misc.warn
      "exact_output: embedded seed runtime.toml is unavailable; cannot backfill the %S lane"
      compaction_exact_lane_id;
    []
  | Some contents ->
    (match Runtime_toml.parse_string contents with
     | Ok (config : Runtime_schema.config) -> config.exact_output_lane_decls
     | Error errors ->
       Log.Misc.warn
         "exact_output: embedded seed runtime.toml parse failed (%d error(s)); cannot backfill the %S lane"
         (List.length errors)
         compaction_exact_lane_id;
       [])
;;

let backfill_required ~seed_lanes lanes =
  let has_compaction_exact (lane : Runtime_schema.exact_output_lane_decl) =
    String.equal lane.id compaction_exact_lane_id
  in
  if List.exists has_compaction_exact lanes
  then lanes, false
  else
    match List.find_opt has_compaction_exact seed_lanes with
    | None -> lanes, false
    | Some seed_lane -> lanes @ [ seed_lane ], true
;;

let with_required_backfill lanes =
  fst (backfill_required ~seed_lanes:(seed_lane_declarations ()) lanes)
;;
