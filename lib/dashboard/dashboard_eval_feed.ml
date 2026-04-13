(** Dashboard_eval_feed — read-only consumer for OAS eval verdicts.

    Parses swiss-verdict JSON (RFC-OAS-002 schema v1) produced by the OAS
    harness and exposes eval snapshots for dashboard rendering.

    This module only reads.  It never writes or modifies eval data.
    Data ownership belongs to OAS. *)

type layer_result_json = {
  layer_name : string;
  passed : bool;
  score : float option;
  evidence : string list;
  detail : string option;
}

type swiss_verdict_json = {
  schema_version : int;
  all_passed : bool;
  coverage : float;
  layer_results : layer_result_json list;
}

type eval_snapshot = {
  agent_name : string;
  session_id : string option;
  worker_run_id : string;
  timestamp : float;
  verdict : swiss_verdict_json;
  baseline_status : string option;
}

(* ── Layer result parsing ────────────────────────────────────────── *)

let read_layer_result_json (json : Yojson.Safe.t)
    : (layer_result_json, string) result =
  let layer_name = Safe_ops.json_string ~default:"" "layer_name" json in
  if layer_name = "" then Error "layer_result: missing layer_name"
  else
    let passed = Safe_ops.json_bool ~default:false "passed" json in
    let score = Safe_ops.json_float_opt "score" json in
    let evidence = Safe_ops.json_string_list "evidence" json in
    let detail = Safe_ops.json_string_opt "detail" json in
    Ok { layer_name; passed; score; evidence; detail }

(* ── Swiss verdict parsing ───────────────────────────────────────── *)

let read_verdict_json (json : Yojson.Safe.t)
    : (swiss_verdict_json, string) result =
  let schema_version = Safe_ops.json_int ~default:0 "schema_version" json in
  if schema_version <> 1 then
    Error
      (Printf.sprintf "unsupported schema_version: %d (expected 1)"
         schema_version)
  else
    let all_passed = Safe_ops.json_bool ~default:false "all_passed" json in
    let coverage = Safe_ops.json_float ~default:0.0 "coverage" json in
    let layer_jsons = Safe_ops.json_list "layer_results" json in
    let rec parse_layers acc = function
      | [] -> Ok (List.rev acc)
      | hd :: tl -> (
          match read_layer_result_json hd with
          | Ok lr -> parse_layers (lr :: acc) tl
          | Error _ as e -> e)
    in
    match parse_layers [] layer_jsons with
    | Ok layer_results ->
        Ok { schema_version; all_passed; coverage; layer_results }
    | Error _ as e -> e

(* ── Eval snapshot parsing ───────────────────────────────────────── *)

let read_snapshot_json ~agent_name (json : Yojson.Safe.t)
    : eval_snapshot option =
  let worker_run_id =
    Safe_ops.json_string ~default:"" "worker_run_id" json
  in
  if worker_run_id = "" then None
  else
    match Safe_ops.json_member_opt "verdict" json with
    | None -> None
    | Some verdict_json -> (
        match read_verdict_json verdict_json with
        | Error _ -> None
        | Ok verdict ->
            let session_id = Safe_ops.json_string_opt "session_id" json in
            let timestamp =
              Safe_ops.json_float ~default:0.0 "timestamp" json
            in
            let baseline_status =
              Safe_ops.json_string_opt "baseline_status" json
            in
            Some
              {
                agent_name;
                session_id;
                worker_run_id;
                timestamp;
                verdict;
                baseline_status;
              })

(* ── File system reading ─────────────────────────────────────────── *)

let eval_base ~base_path =
  Filename.concat (Filename.concat base_path ".oas") "eval"

let eval_dir ~base_path ~agent_name =
  Filename.concat (eval_base ~base_path) agent_name

let list_agents ~base_path =
  let dir = eval_base ~base_path in
  try
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name ->
         Sys.is_directory (Filename.concat dir name))
    |> List.sort String.compare
  with Sys_error _ -> []

let read_latest ~base_path ~agent_name ~limit =
  let dir = eval_dir ~base_path ~agent_name in
  let files =
    try
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.sort (fun a b -> String.compare b a)
    with Sys_error _ -> []
  in
  let rec collect acc remaining = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | filename :: rest ->
        let path = Filename.concat dir filename in
        let snapshot =
          match Safe_ops.read_json_file_safe path with
          | Error _ -> None
          | Ok json -> read_snapshot_json ~agent_name json
        in
        (match snapshot with
        | Some s -> collect (s :: acc) (remaining - 1) rest
        | None -> collect acc remaining rest)
  in
  collect [] limit files

(* ── JSON serialization ──────────────────────────────────────────── *)

let layer_result_to_json (lr : layer_result_json) : Yojson.Safe.t =
  `Assoc
    [
      ("layer_name", `String lr.layer_name);
      ("passed", `Bool lr.passed);
      ("score", Json_util.float_opt_to_json lr.score);
      ("evidence", `List (List.map (fun s -> `String s) lr.evidence));
      ("detail", Json_util.string_opt_to_json lr.detail);
    ]

let verdict_to_json (v : swiss_verdict_json) : Yojson.Safe.t =
  `Assoc
    [
      ("schema_version", `Int v.schema_version);
      ("all_passed", `Bool v.all_passed);
      ("coverage", `Float v.coverage);
      ( "layer_results",
        `List (List.map layer_result_to_json v.layer_results) );
    ]

let snapshot_to_json (s : eval_snapshot) : Yojson.Safe.t =
  `Assoc
    [
      ("agent_name", `String s.agent_name);
      ("session_id", Json_util.string_opt_to_json s.session_id);
      ("worker_run_id", `String s.worker_run_id);
      ("timestamp", `Float s.timestamp);
      ("verdict", verdict_to_json s.verdict);
      ("baseline_status", Json_util.string_opt_to_json s.baseline_status);
    ]
