(** Artifact_store — MASC CDAL artifact storage backend.

    Filesystem-first storage for evaluator results, intervention
    summaries, and acceptance verdicts. *)

module U = Yojson.Safe.Util

type artifact_kind =
  | Evaluator_result
  | Intervention_summary
  | Acceptance_verdict
  | Evidence_bundle

type artifact_metadata = {
  artifact_id : string;
  kind : artifact_kind;
  producer : string;
  schema_version : string;
  created_at_iso : string;
  owner : string;
  session_id : string;
}

type config = {
  base_dir : string;
}

let kind_to_string = function
  | Evaluator_result -> "evaluator_result"
  | Intervention_summary -> "intervention_summary"
  | Acceptance_verdict -> "acceptance_verdict"
  | Evidence_bundle -> "evidence_bundle"

let kind_of_string = function
  | "evaluator_result" -> Ok Evaluator_result
  | "intervention_summary" -> Ok Intervention_summary
  | "acceptance_verdict" -> Ok Acceptance_verdict
  | "evidence_bundle" -> Ok Evidence_bundle
  | other -> Error (Printf.sprintf "unknown artifact kind: %s" other)

let default_config ~session_id =
  let home = Option.value ~default:"/tmp" (Sys.getenv_opt "HOME") in
  { base_dir = Filename.concat home (Printf.sprintf ".masc/sessions/%s/artifacts" session_id) }

(* --- Filesystem helpers --- *)

let kind_dir config kind =
  Filename.concat config.base_dir (Printf.sprintf "cdal/%s" (kind_to_string kind))

let artifact_path config kind artifact_id =
  Filename.concat (kind_dir config kind) (artifact_id ^ ".json")

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    (try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  end

let init config =
  List.iter
    (fun kind -> mkdir_p (kind_dir config kind))
    [ Evaluator_result; Intervention_summary; Acceptance_verdict; Evidence_bundle ]

(* --- Metadata serialization --- *)

let metadata_to_yojson (m : artifact_metadata) : Yojson.Safe.t =
  `Assoc
    [
      ("artifact_id", `String m.artifact_id);
      ("kind", `String (kind_to_string m.kind));
      ("producer", `String m.producer);
      ("schema_version", `String m.schema_version);
      ("created_at_iso", `String m.created_at_iso);
      ("owner", `String m.owner);
      ("session_id", `String m.session_id);
    ]

let metadata_of_yojson (json : Yojson.Safe.t) :
    (artifact_metadata, string) result =
  try
    let artifact_id = json |> U.member "artifact_id" |> U.to_string in
    let kind_str = json |> U.member "kind" |> U.to_string in
    match kind_of_string kind_str with
    | Error e -> Error e
    | Ok kind ->
        Ok
          {
            artifact_id;
            kind;
            producer = json |> U.member "producer" |> U.to_string;
            schema_version = json |> U.member "schema_version" |> U.to_string;
            created_at_iso = json |> U.member "created_at_iso" |> U.to_string;
            owner = json |> U.member "owner" |> U.to_string;
            session_id = json |> U.member "session_id" |> U.to_string;
          }
  with
  | U.Type_error (msg, _) -> Error (Printf.sprintf "metadata parse error: %s" msg)
  | Not_found -> Error "metadata parse error: missing required field"

(* --- Envelope: metadata + payload --- *)

let envelope_to_json metadata payload =
  `Assoc
    [
      ("_metadata", metadata_to_yojson metadata);
      ("payload", payload);
    ]

let envelope_of_json json =
  try
    let meta_json = json |> U.member "_metadata" in
    let payload = json |> U.member "payload" in
    match metadata_of_yojson meta_json with
    | Ok metadata -> Ok (metadata, payload)
    | Error e -> Error e
  with
  | U.Type_error (msg, _) -> Error (Printf.sprintf "envelope parse error: %s" msg)
  | Not_found -> Error "envelope parse error: missing _metadata or payload"

(* --- Store operations --- *)

let write config ~(metadata : artifact_metadata) ~(payload : Yojson.Safe.t) =
  let dir = kind_dir config metadata.kind in
  mkdir_p dir;
  let path = artifact_path config metadata.kind metadata.artifact_id in
  let envelope = envelope_to_json metadata payload in
  Fs_compat.save_file path (Yojson.Safe.pretty_to_string envelope)

let read config ~kind ~artifact_id =
  let path = artifact_path config kind artifact_id in
  if not (Sys.file_exists path) then
    Error (Printf.sprintf "artifact not found: %s" path)
  else
    try
      let content = Fs_compat.load_file path in
      let json = Yojson.Safe.from_string content in
      envelope_of_json json
    with
    | Yojson.Json_error msg -> Error (Printf.sprintf "json parse error: %s" msg)
    | Sys_error msg -> Error msg

let list_artifacts config ~kind =
  let dir = kind_dir config kind in
  if not (Sys.file_exists dir) then []
  else
    let entries = Sys.readdir dir |> Array.to_list in
    entries
    |> List.filter (fun name -> Filename.check_suffix name ".json")
    |> List.filter_map (fun name ->
           let artifact_id = Filename.chop_suffix name ".json" in
           match read config ~kind ~artifact_id with
           | Ok (metadata, _) -> Some metadata
           | Error _ -> None)

let make_ref ~session_id ~kind ~artifact_id =
  Printf.sprintf "masc-artifact://%s/%s/%s" session_id (kind_to_string kind)
    artifact_id
