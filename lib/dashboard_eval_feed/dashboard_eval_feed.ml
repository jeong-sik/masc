(** Dashboard_eval_feed — read-only consumer for AGENT_CORE eval verdicts.

    Parses swiss-verdict JSON (Agent Core contract schema v1) produced by the AGENT_CORE
    harness and exposes eval snapshots for dashboard rendering.

    This module only reads.  It never writes or modifies eval data.
    Data ownership belongs to AGENT_CORE. *)

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
    (* RFC-AC-002 lists all_passed, coverage and layer_results beside
       schema_version in the report's required set, so a report missing one is
       damaged. Defaulting them turned that into a passing-shaped verdict with
       no layers, which reads on the dashboard exactly like a run that had
       nothing to check (#29355). *)
    let required name project =
      match Safe_ops.json_member_opt name json with
      | None -> Error (Printf.sprintf "schema_version 1 report requires %S" name)
      | Some value ->
          (match project value with
           | Some projected -> Ok projected
           | None ->
               Error
                 (Printf.sprintf
                    "schema_version 1 report field %S has the wrong JSON type"
                    name))
    in
    let open Result.Syntax in
    let* all_passed =
      required "all_passed" (function `Bool b -> Some b | _ -> None)
    in
    let* coverage =
      required "coverage" (function
        | `Float f -> Some f
        | `Int i -> Some (float_of_int i)
        | _ -> None)
    in
    let* layer_jsons =
      required "layer_results" (function `List l -> Some l | _ -> None)
    in
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
  Filename.concat (Filename.concat base_path ".agent_core") "eval"

let warn_unreadable ~op ~path msg =
  Log.Dashboard.warn "[eval_feed.%s] path unreadable at %s: %s" op path msg

let warn_owned_error ~op ~path (error : Fs_compat.owned_regular_file_read_error) =
  let initial_missing =
    match error.failure with
    | Fs_compat.Owned_file_operation_failed { cause = Unix.Unix_error (code, _, _); _ } ->
      code = Unix.ENOENT && Option.is_none error.close_failure
    | Fs_compat.Owned_file_operation_failed _
    | Fs_compat.Ownership_boundary_rejected _
    | Fs_compat.Path_is_not_regular_file _
    | Fs_compat.Filesystem_identity_changed _
    | Fs_compat.Owned_path_owner_mismatch _
    | Fs_compat.Owned_path_writable_by_others _ -> false
  in
  if not initial_missing then
    warn_unreadable ~op ~path (Fs_compat.owned_regular_file_read_error_to_string error)

let with_workspace_root ~op ~base_path read =
  try
    let base_path = if Filename.is_relative base_path
      then Filename.concat (Sys.getcwd ()) base_path else base_path in
    read base_path
  with
  | (Unix.Unix_error _ | Sys_error _ | Eio.Io _) as error ->
    warn_unreadable ~op ~path:base_path (Printexc.to_string error);
    []

let directory_names ~op ~base_path path =
  match Fs_compat.read_owned_directory ~ownership_root:base_path path with
  | Ok names -> names
  | Error error -> warn_owned_error ~op ~path error; []

let list_agents ~base_path =
  with_workspace_root ~op:"list_agents" ~base_path (fun base_path ->
    let dir = eval_base ~base_path in
    directory_names ~op:"list_agents" ~base_path dir
    |> List.filter (fun name ->
      let path = Filename.concat dir name in
      match Fs_compat.exact_path_kind ~follow:false path with
      | Fs_compat.Exact_kind Unix.S_DIR -> true
      | Fs_compat.Exact_kind (Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK)
      | Fs_compat.Exact_missing | Fs_compat.Exact_unknown -> false
      | exception ((Unix.Unix_error _ | Sys_error _ | Eio.Io _) as error) ->
        warn_unreadable ~op:"list_agents" ~path (Printexc.to_string error);
        false))

let read_latest ~base_path ~agent_name ~limit =
  match Fs_compat.owned_relative_path [agent_name] with
  | Error _ -> []
  | Ok relative ->
    with_workspace_root ~op:"read_latest" ~base_path (fun base_path ->
      let dir = Filename.concat (eval_base ~base_path)
        (Fs_compat.owned_relative_path_to_string relative) in
      let files = directory_names ~op:"read_latest" ~base_path dir
        |> List.filter (fun name -> Filename.check_suffix name ".json")
        |> List.sort (fun a b -> String.compare b a) in
      let rec collect acc remaining = function
        | [] -> List.rev acc
        | _ when remaining <= 0 -> List.rev acc
        | filename :: rest ->
          let path = Filename.concat dir filename in
          let snapshot =
            match Fs_compat.load_owned_regular_file ~ownership_root:base_path path with
            | Ok None -> None
            | Error error -> warn_owned_error ~op:"read_latest" ~path error; None
            | Ok (Some contents) ->
              (match Yojson.Safe.from_string contents with
               | json -> read_snapshot_json ~agent_name json
               | exception Yojson.Json_error _ -> None)
          in
          (match snapshot with
           | Some snapshot -> collect (snapshot :: acc) (remaining - 1) rest
           | None -> collect acc remaining rest)
      in
      collect [] limit files)

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
