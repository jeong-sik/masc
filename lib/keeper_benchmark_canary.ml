open Keeper_types

type recommendation =
  { keeper_profile : string
  ; model_label : string
  ; composite_score : float
  ; task_pass_rate : float
  ; stability_score : float option
  ; cases_total : int
  ; cases_passed : int
  }

type manifest =
  { version : int
  ; generated_at : string
  ; source_summary_path : string option
  ; recommendations : recommendation list
  }

type cache_entry =
  { path : string
  ; mtime : float
  ; manifest : manifest option
  }

let cache : cache_entry option ref = ref None
let trim = String.trim

let normalize_string_list items =
  items |> List.map trim |> List.filter (fun item -> item <> "") |> dedupe_keep_order
;;

let default_manifest_path () =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path:(Env_config.base_path ()))
       "bench")
    "keeper_model_recommendations.json"
;;

let enabled () =
  Keeper_config.bool_of_env_default "MASC_KEEPER_BENCH_CANARY_ENABLED" ~default:false
;;

let manifest_path () =
  match Env_config_core.raw_value_opt "MASC_KEEPER_BENCH_CANARY_PATH" with
  | Some path when trim path <> "" -> trim path
  | _ -> default_manifest_path ()
;;

let row_to_recommendation (row : Tool_call_quality_benchmark.summary_row)
  : recommendation option
  =
  match row.provider, row.model, row.keeper_profile with
  | Some provider, Some model, Some keeper_profile
    when row.cases_total > 0
         && row.cases_passed = row.cases_total
         && row.unsupported_runs = 0
         && row.runtime_unreachable_runs = 0 ->
    Some
      { keeper_profile
      ; model_label = provider ^ ":" ^ model
      ; composite_score = row.composite_score
      ; task_pass_rate = row.task_pass_rate
      ; stability_score = row.stability_score
      ; cases_total = row.cases_total
      ; cases_passed = row.cases_passed
      }
  | _ -> None
;;

let compare_float_option_desc a b =
  match a, b with
  | Some left, Some right -> Float.compare right left
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> 0
;;

let compare_recommendation left right =
  match Float.compare right.composite_score left.composite_score with
  | 0 ->
    (match Float.compare right.task_pass_rate left.task_pass_rate with
     | 0 ->
       (match compare_float_option_desc left.stability_score right.stability_score with
        | 0 ->
          (match Int.compare right.cases_total left.cases_total with
           | 0 ->
             (match Int.compare right.cases_passed left.cases_passed with
              | 0 -> String.compare left.model_label right.model_label
              | cmp -> cmp)
           | cmp -> cmp)
        | cmp -> cmp)
     | cmp -> cmp)
  | cmp -> cmp
;;

let generated_at_utc () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf
    "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec
;;

let build_manifest
      ?source_summary_path
      (summary : Tool_call_quality_benchmark.benchmark_summary)
  : manifest
  =
  let grouped = Hashtbl.create 8 in
  summary.grouped_by_provider_model_keeper
  |> List.filter_map row_to_recommendation
  |> List.iter (fun recommendation ->
    let current = Hashtbl.find_opt grouped recommendation.keeper_profile in
    match current with
    | Some best when compare_recommendation recommendation best >= 0 -> ()
    | _ -> Hashtbl.replace grouped recommendation.keeper_profile recommendation);
  let recommendations =
    Hashtbl.to_seq_values grouped
    |> List.of_seq
    |> List.sort (fun left right ->
      match String.compare left.keeper_profile right.keeper_profile with
      | 0 -> compare_recommendation left right
      | cmp -> cmp)
  in
  { version = 1
  ; generated_at = generated_at_utc ()
  ; source_summary_path
  ; recommendations
  }
;;

let recommendation_to_yojson (recommendation : recommendation) =
  `Assoc
    [ "keeper_profile", `String recommendation.keeper_profile
    ; "model_label", `String recommendation.model_label
    ; "composite_score", `Float recommendation.composite_score
    ; "task_pass_rate", `Float recommendation.task_pass_rate
    ; ( "stability_score"
      , Option.fold
          ~none:`Null
          ~some:(fun value -> `Float value)
          recommendation.stability_score )
    ; "cases_total", `Int recommendation.cases_total
    ; "cases_passed", `Int recommendation.cases_passed
    ]
;;

let manifest_to_yojson (manifest : manifest) =
  `Assoc
    [ "version", `Int manifest.version
    ; "generated_at", `String manifest.generated_at
    ; ( "source_summary_path"
      , Option.fold
          ~none:`Null
          ~some:(fun value -> `String value)
          manifest.source_summary_path )
    ; ( "recommendations"
      , `List (List.map recommendation_to_yojson manifest.recommendations) )
    ]
;;

let parse_recommendation json =
  let keeper_profile = Safe_ops.json_string ~default:"" "keeper_profile" json |> trim in
  let model_label = Safe_ops.json_string ~default:"" "model_label" json |> trim in
  if keeper_profile = "" || model_label = ""
  then None
  else
    Some
      { keeper_profile
      ; model_label
      ; composite_score = Safe_ops.json_float ~default:0.0 "composite_score" json
      ; task_pass_rate = Safe_ops.json_float ~default:0.0 "task_pass_rate" json
      ; stability_score = Safe_ops.json_float_opt "stability_score" json
      ; cases_total = Safe_ops.json_int ~default:0 "cases_total" json
      ; cases_passed = Safe_ops.json_int ~default:0 "cases_passed" json
      }
;;

let parse_manifest json =
  match json with
  | `Assoc _ ->
    Some
      { version = Safe_ops.json_int ~default:1 "version" json
      ; generated_at = Safe_ops.json_string ~default:"" "generated_at" json
      ; source_summary_path = Safe_ops.json_string_opt "source_summary_path" json
      ; recommendations =
          (match Yojson.Safe.Util.member "recommendations" json with
           | `List items -> items
           | _ -> [])
          |> List.filter_map parse_recommendation
      }
  | _ -> None
;;

let stat_mtime path =
  try Some (Unix.stat path).Unix.st_mtime with
  | Unix.Unix_error _ -> None
;;

let load_manifest_from_file path =
  match Safe_ops.read_json_file_safe path with
  | Error err ->
    Log.Keeper.warn "keeper benchmark canary: failed to read %s: %s" path err;
    None
  | Ok json ->
    (match parse_manifest json with
     | Some manifest -> Some manifest
     | None ->
       Log.Keeper.warn "keeper benchmark canary: invalid manifest shape at %s" path;
       None)
;;

let load_manifest_uncached path =
  let manifest = load_manifest_from_file path in
  let mtime = Option.value ~default:(-1.0) (stat_mtime path) in
  cache := Some { path; mtime; manifest };
  manifest
;;

let load_manifest () =
  let path = manifest_path () in
  match stat_mtime path, !cache with
  | None, Some cached when String.equal cached.path path && cached.mtime < 0.0 ->
    cached.manifest
  | None, _ ->
    cache := Some { path; mtime = -1.0; manifest = None };
    None
  | Some mtime, Some cached
    when String.equal cached.path path && Float.equal cached.mtime mtime ->
    cached.manifest
  | Some _, _ -> load_manifest_uncached path
;;

let candidate_keeper_profiles keeper_name =
  let keeper_name = trim keeper_name in
  if keeper_name = ""
  then []
  else if
    String.length keeper_name > 6 && String.equal (String.sub keeper_name 0 6) "bench-"
  then (
    let bare = String.sub keeper_name 6 (String.length keeper_name - 6) in
    normalize_string_list [ keeper_name; bare ])
  else normalize_string_list [ keeper_name; "bench-" ^ keeper_name ]
;;

let recommended_model_label_for_keeper ~keeper_name =
  if not (enabled ())
  then None
  else (
    match load_manifest () with
    | None -> None
    | Some manifest ->
      let candidates = candidate_keeper_profiles keeper_name in
      candidates
      |> List.find_map (fun keeper_profile ->
        manifest.recommendations
        |> List.find_map (fun recommendation ->
          if String.equal recommendation.keeper_profile keeper_profile
          then Some recommendation.model_label
          else None)))
;;

let reset_for_testing () = cache := None
