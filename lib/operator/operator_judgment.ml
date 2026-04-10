open Yojson.Safe.Util

open Result_syntax

type target_type =
  | Room
  | Execution_session

type record = {
  judgment_id : string;
  surface : string;
  target_type : target_type;
  target_id : string option;
  status : string;
  summary : string;
  confidence : float;
  generated_at : string;
  generated_at_unix : float;
  fresh_until : string;
  fresh_until_unix : float;
  keeper_name : string;
  model_name : string option;
  runtime_name : string option;
  evidence_refs : string list;
  recommended_action : Yojson.Safe.t option;
  supersedes : string list;
  fallback_used : bool;
  disagreement_with_truth : bool;
}

let target_type_to_string = function
  | Room -> "namespace"
  | Execution_session -> "execution_session"

let target_type_of_string = function
  | "room" | "namespace" -> Some Room
  | "execution_session" -> Some Execution_session
  | _ -> None

let option_to_yojson = Json_util.option_to_yojson

let ensure_dir path =
  Fs_compat.mkdir_p path

let operator_dir config =
  Filename.concat (Room.masc_dir config) "operator"

let judgments_path config =
  Filename.concat (operator_dir config) "judgments.jsonl"

let generate_id () =
  "judg-" ^ String.sub (Auth.generate_token ()) 0 20

let key_of ~surface ~target_type ~target_id =
  let target =
    match target_id with
    | Some value when String.trim value <> "" -> String.trim value
    | _ -> "__room__"
  in
  String.concat ":" [ surface; target_type_to_string target_type; target ]

let to_yojson (value : record) =
  `Assoc
    [
      ("judgment_id", `String value.judgment_id);
      ("surface", `String value.surface);
      ("target_type", `String (target_type_to_string value.target_type));
      ("target_id", option_to_yojson (fun v -> `String v) value.target_id);
      ("status", `String value.status);
      ("summary", `String value.summary);
      ("confidence", `Float value.confidence);
      ("generated_at", `String value.generated_at);
      ("generated_at_unix", `Float value.generated_at_unix);
      ("fresh_until", `String value.fresh_until);
      ("fresh_until_unix", `Float value.fresh_until_unix);
      ("keeper_name", `String value.keeper_name);
      ("model_name", option_to_yojson (fun v -> `String v) value.model_name);
      ("runtime_name", option_to_yojson (fun v -> `String v) value.runtime_name);
      ( "evidence_refs",
        `List (List.map (fun item -> `String item) value.evidence_refs) );
      ("recommended_action", option_to_yojson (fun v -> v) value.recommended_action);
      ("supersedes", `List (List.map (fun item -> `String item) value.supersedes));
      ("fallback_used", `Bool value.fallback_used);
      ("disagreement_with_truth", `Bool value.disagreement_with_truth);
      ("provenance", `String "judgment");
    ]

let of_yojson json =
  try
    let* target_type =
      match json |> member "target_type" |> to_string_option with
      | Some value -> (
          match target_type_of_string value with
          | Some parsed -> Ok parsed
          | None -> Error "invalid target_type")
      | None -> Error "missing target_type"
    in
    Ok
      {
        judgment_id = json |> member "judgment_id" |> to_string;
        surface = json |> member "surface" |> to_string;
        target_type;
        target_id = json |> member "target_id" |> to_string_option;
        status =
          json |> member "status" |> to_string_option
          |> Option.value ~default:"active";
        summary = json |> member "summary" |> to_string;
        confidence =
          (match json |> member "confidence" with
          | `Float value -> value
          | `Int value -> float_of_int value
          | _ -> 0.0);
        generated_at = json |> member "generated_at" |> to_string;
        generated_at_unix =
          (match json |> member "generated_at_unix" with
          | `Float value -> value
          | `Int value -> float_of_int value
          | _ -> Types.parse_iso8601 (json |> member "generated_at" |> to_string));
        fresh_until = json |> member "fresh_until" |> to_string;
        fresh_until_unix =
          (match json |> member "fresh_until_unix" with
          | `Float value -> value
          | `Int value -> float_of_int value
          | _ -> Types.parse_iso8601 (json |> member "fresh_until" |> to_string));
        keeper_name =
          json |> member "keeper_name" |> to_string_option
          |> Option.value ~default:"operator-judge";
        model_name = json |> member "model_name" |> to_string_option;
        runtime_name = json |> member "runtime_name" |> to_string_option;
        evidence_refs =
          (match json |> member "evidence_refs" with
          | `List items -> List.filter_map to_string_option items
          | _ -> []);
        recommended_action =
          (match json |> member "recommended_action" with
          | `Assoc _ as value -> Some value
          | _ -> None);
        supersedes =
          (match json |> member "supersedes" with
          | `List items -> List.filter_map to_string_option items
          | _ -> []);
        fallback_used =
          json |> member "fallback_used" |> to_bool_option
          |> Option.value ~default:false;
        disagreement_with_truth =
          json |> member "disagreement_with_truth" |> to_bool_option
          |> Option.value ~default:false;
      }
  with Type_error (msg, _) | Failure msg -> Error msg

let generated_at_unix value =
  value.generated_at_unix

let fresh_until_unix value =
  value.fresh_until_unix

let is_fresh ?(now = Unix.gettimeofday ()) value =
  fresh_until_unix value > now

let load_all config =
  let path = judgments_path config in
  Fs_compat.load_jsonl path
  |> List.filter_map (fun json ->
         try
           match of_yojson json with
           | Ok value -> Some value
           | Error _ -> None
         with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
           Log.Governance.warn "operator judgment parse: %s" (Printexc.to_string exn);
           None)

let append config values =
  ensure_dir (operator_dir config);
  let path = judgments_path config in
  List.iter
    (fun value ->
      Fs_compat.append_jsonl path (to_yojson value))
    values

let latest_by_key config =
  let table = Hashtbl.create 16 in
  load_all config
  |> List.iter (fun value ->
         let key =
           key_of ~surface:value.surface ~target_type:value.target_type
             ~target_id:value.target_id
         in
         match Hashtbl.find_opt table key with
         | Some current when generated_at_unix current >= generated_at_unix value -> ()
         | _ -> Hashtbl.replace table key value);
  table

let latest_active config ~surface ~target_type ~target_id =
  let table = latest_by_key config in
  Hashtbl.find_opt table (key_of ~surface ~target_type ~target_id)

let latest_active_json config ~surface ~target_type ~target_id =
  match latest_active config ~surface ~target_type ~target_id with
  | Some value -> Some (to_yojson value)
  | None -> None

let record config ~surface ~target_type ~target_id ~summary ~confidence
    ?model_name ?runtime_name ?recommended_action ?(evidence_refs = [])
    ?(fallback_used = false) ?(disagreement_with_truth = false) ~generated_at
    ?generated_at_unix ~fresh_until ?fresh_until_unix ~keeper_name () =
  let supersedes =
    match latest_active config ~surface ~target_type ~target_id with
    | Some value -> [ value.judgment_id ]
    | None -> []
  in
  let generated_at_unix =
    match generated_at_unix with
    | Some value -> value
    | None -> Unix.gettimeofday ()
  in
  let fresh_until_unix =
    match fresh_until_unix with
    | Some value -> value
    | None -> Types.parse_iso8601 fresh_until
  in
  let value =
    {
      judgment_id = generate_id ();
      surface;
      target_type;
      target_id;
      status = "active";
      summary = String.trim summary;
      confidence = max 0.0 (min 1.0 confidence);
      generated_at;
      generated_at_unix;
      fresh_until;
      fresh_until_unix;
      keeper_name;
      model_name;
      runtime_name;
      evidence_refs =
        evidence_refs
        |> List.filter_map (fun raw ->
               let trimmed = String.trim raw in
               if trimmed = "" then None else Some trimmed);
      recommended_action;
      supersedes;
      fallback_used;
      disagreement_with_truth;
    }
  in
  append config [ value ];
  value
