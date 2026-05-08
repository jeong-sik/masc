type config = { root : string }

type resolved_ref =
  { run_id : string
  ; subpath : string
  ; path : string
  }

open Result_syntax

let default_config =
  let home =
    try Sys.getenv "HOME" with
    | Not_found -> "/tmp"
  in
  { root = Filename.concat home ".oas" }
;;

let proofs_dir config = Filename.concat config.root "proofs"
let run_dir config ~run_id = Filename.concat (proofs_dir config) run_id
let traces_dir config ~run_id = Filename.concat (run_dir config ~run_id) "tool_traces"
let evidence_dir config ~run_id = Filename.concat (run_dir config ~run_id) "evidence"

let contract_path config ~run_id =
  Filename.concat (run_dir config ~run_id) "contract.json"
;;

let manifest_path config ~run_id =
  Filename.concat (run_dir config ~run_id) "manifest.json"
;;

let log_error context = function
  | Ok () -> ()
  | Error err -> Printf.eprintf "[proof_store] %s: %s\n%!" context (Error.to_string err)
;;

let init_run config ~run_id =
  log_error "mkdir traces" (Fs_result.ensure_dir (traces_dir config ~run_id));
  log_error "mkdir evidence" (Fs_result.ensure_dir (evidence_dir config ~run_id))
;;

let write_json context path json =
  let content = Yojson.Safe.pretty_to_string json ^ "\n" in
  log_error context (Fs_result.write_file path content)
;;

let write_manifest config ~run_id proof =
  write_json "write manifest" (manifest_path config ~run_id) (Cdal_proof.to_json proof)
;;

let write_contract config ~run_id contract =
  write_json
    "write contract"
    (contract_path config ~run_id)
    (Risk_contract.to_yojson contract)
;;

let append_tool_trace config ~run_id ~trace_id json =
  let path = Filename.concat (traces_dir config ~run_id) (trace_id ^ ".jsonl") in
  let line = Yojson.Safe.to_string json ^ "\n" in
  log_error "append trace" (Fs_result.append_file path line)
;;

let write_evidence config ~run_id ~ref_id json =
  let path = Filename.concat (evidence_dir config ~run_id) (ref_id ^ ".json") in
  write_json "write evidence" path json
;;

let make_ref ~run_id ~subpath = Printf.sprintf "proof-store://%s/%s" run_id subpath
let ref_prefix = "proof-store://"
let ref_prefix_len = String.length ref_prefix

let validate_ref_run_id run_id =
  if run_id = ""
  then Error "artifact ref run_id is empty"
  else if run_id = "." || run_id = ".."
  then Error (Printf.sprintf "artifact ref has invalid run_id: %s" run_id)
  else Ok ()
;;

let validate_ref_subpath subpath =
  let segments = String.split_on_char '/' subpath in
  if subpath = ""
  then Error "artifact ref subpath is empty"
  else if List.exists (fun seg -> seg = "" || seg = "." || seg = "..") segments
  then Error (Printf.sprintf "artifact ref has invalid subpath: %s" subpath)
  else Ok ()
;;

let resolve_ref config (ref_ : Cdal_proof.artifact_ref) =
  let len = String.length ref_ in
  if len <= ref_prefix_len || String.sub ref_ 0 ref_prefix_len <> ref_prefix
  then Error (Printf.sprintf "invalid proof-store ref: %s" ref_)
  else (
    let rel = String.sub ref_ ref_prefix_len (len - ref_prefix_len) in
    match String.index_opt rel '/' with
    | None -> Error (Printf.sprintf "artifact ref missing subpath: %s" ref_)
    | Some slash_idx ->
      let run_id = String.sub rel 0 slash_idx in
      let subpath = String.sub rel (slash_idx + 1) (String.length rel - slash_idx - 1) in
      let* () = validate_ref_run_id run_id in
      (match validate_ref_subpath subpath with
       | Error _ as err -> err
       | Ok () ->
         Ok { run_id; subpath; path = Filename.concat (run_dir config ~run_id) subpath }))
;;

let read_json_path path =
  let open Result in
  let* content = Fs_result.read_file path |> map_error Error.to_string in
  try Ok (Yojson.Safe.from_string content) with
  | Yojson.Json_error msg -> Error (Printf.sprintf "JSON parse error in %s: %s" path msg)
;;

let read_json config ref_ =
  let* resolved = resolve_ref config ref_ in
  read_json_path resolved.path
;;

let read_jsonl config ref_ =
  let* resolved = resolve_ref config ref_ in
  let* content = Fs_result.read_file resolved.path |> Result.map_error Error.to_string in
  let lines = String.split_on_char '\n' content in
  let rec parse acc line_no = function
    | [] -> Ok (List.rev acc)
    | line :: rest when String.trim line = "" -> parse acc (line_no + 1) rest
    | line :: rest ->
      (try
         let json = Yojson.Safe.from_string line in
         parse (json :: acc) (line_no + 1) rest
       with
       | Yojson.Json_error msg ->
         Error
           (Printf.sprintf
              "JSONL parse error in %s at line %d: %s"
              resolved.path
              line_no
              msg))
  in
  parse [] 1 lines
;;

let load_manifest config ~run_id =
  let path = manifest_path config ~run_id in
  let* json = read_json_path path in
  Cdal_proof.of_json json
  |> Result.map_error (fun msg ->
    Printf.sprintf "manifest decode error in %s: %s" path msg)
  |> Result.map (fun proof -> proof, json)
;;

let load_contract config ~run_id =
  let path = contract_path config ~run_id in
  let* json = read_json_path path in
  Risk_contract.of_yojson json
  |> Result.map_error (fun msg ->
    Printf.sprintf "contract decode error in %s: %s" path msg)
  |> Result.map (fun contract -> contract, json)
;;

let list_runs config =
  if not (Sys.file_exists (proofs_dir config))
  then Ok []
  else
    Fs_result.read_dir (proofs_dir config)
    |> Result.map_error Error.to_string
    |> Result.map (fun entries ->
      List.filter
        (fun entry ->
           try Sys.is_directory (run_dir config ~run_id:entry) with
           | Sys_error _ -> false)
        entries)
;;

(* ================================================================ *)
(* Cross-run window support                                          *)
(* ================================================================ *)

type run_info =
  { run_id : string
  ; ended_at : float
  ; schema_version : int
  ; scope : string option
  }

type window_bounds =
  { max_runs : int
  ; max_bytes : int
  }

let default_window_bounds = { max_runs = 50; max_bytes = 50 * 1024 * 1024 }

let list_runs_ordered config ?scope ?(bounds = default_window_bounds) () =
  let* run_ids = list_runs config in
  let infos = ref [] in
  let errors = ref [] in
  List.iter
    (fun run_id ->
       match load_manifest config ~run_id with
       | Ok (proof, _json) ->
         let matches_scope =
           match scope with
           | None -> true
           | Some s -> proof.Cdal_proof.scope = Some s
         in
         if matches_scope
         then
           infos
           := { run_id
              ; ended_at = proof.Cdal_proof.ended_at
              ; schema_version = proof.Cdal_proof.schema_version
              ; scope = proof.Cdal_proof.scope
              }
              :: !infos
       | Error msg -> errors := Printf.sprintf "run %s: %s" run_id msg :: !errors)
    run_ids;
  let sorted =
    List.sort
      (fun a b ->
         let c = Float.compare a.ended_at b.ended_at in
         if c <> 0 then c else String.compare a.run_id b.run_id)
      !infos
  in
  if List.length sorted > bounds.max_runs
  then
    Error
      (Printf.sprintf
         "run count %d exceeds max_runs %d"
         (List.length sorted)
         bounds.max_runs)
  else Ok (sorted, List.rev !errors)
;;

let load_window config ~run_ids ?(bounds = default_window_bounds) () =
  if List.length run_ids > bounds.max_runs
  then
    Error
      (Printf.sprintf
         "run count %d exceeds max_runs %d"
         (List.length run_ids)
         bounds.max_runs)
  else (
    let loaded = ref [] in
    let errors = ref [] in
    let bytes_total = ref 0 in
    let check_bytes () =
      if !bytes_total > bounds.max_bytes
      then
        Some
          (Printf.sprintf
             "total bytes %d exceeds max_bytes %d"
             !bytes_total
             bounds.max_bytes)
      else None
    in
    let rec process = function
      | [] -> Ok ()
      | run_id :: rest ->
        (match check_bytes () with
         | Some msg -> Error msg
         | None ->
           (match load_manifest config ~run_id with
            | Ok (proof, json) ->
              let json_str = Yojson.Safe.to_string json in
              bytes_total := !bytes_total + String.length json_str;
              (match check_bytes () with
               | Some msg -> Error msg
               | None ->
                 loaded := (proof, json) :: !loaded;
                 process rest)
            | Error msg ->
              errors := Printf.sprintf "run %s: %s" run_id msg :: !errors;
              process rest))
    in
    match process run_ids with
    | Error msg -> Error msg
    | Ok () -> Ok (List.rev !loaded, List.rev !errors))
;;
