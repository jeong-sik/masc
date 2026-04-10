module U = Yojson.Safe.Util

open Keeper_types

type status =
  | Pending
  | Cleared

type record = {
  version : int;
  keeper_name : string;
  blocker_class : string;
  summary : string;
  failure_reason : string option;
  trace_id : string option;
  generation : int option;
  committed_tools : string list;
  opened_at : string;
  updated_at : string;
  status : status;
  resolution : string option;
  evidence_refs : string list;
  cleared_at : string option;
  cleared_by : string option;
  clear_idempotency_key : string option;
}

type clear_outcome =
  | Cleared_record of record
  | Already_cleared of record
  | No_record

let record_version = 1

let status_to_string = function
  | Pending -> "pending"
  | Cleared -> "cleared"

let status_of_string = function
  | "pending" -> Some Pending
  | "cleared" -> Some Cleared
  | _ -> None

let record_path (config : Room.config) keeper_name =
  Filename.concat (keeper_dir config) (keeper_name ^ ".manual_reconcile.json")

let now_iso () =
  Types.iso8601_of_unix_seconds (Time_compat.now ())

let string_option_to_json = Json_util.option_to_yojson (fun value -> `String value)

let int_option_to_json = Json_util.option_to_yojson (fun value -> `Int value)

let string_list_to_json values =
  `List (List.map (fun value -> `String value) values)

let record_to_yojson (record : record) =
  `Assoc
    [
      ("version", `Int record.version);
      ("keeper_name", `String record.keeper_name);
      ("blocker_class", `String record.blocker_class);
      ("summary", `String record.summary);
      ("failure_reason", string_option_to_json record.failure_reason);
      ("trace_id", string_option_to_json record.trace_id);
      ("generation", int_option_to_json record.generation);
      ("committed_tools", string_list_to_json record.committed_tools);
      ("opened_at", `String record.opened_at);
      ("updated_at", `String record.updated_at);
      ("status", `String (status_to_string record.status));
      ("resolution", string_option_to_json record.resolution);
      ("evidence_refs", string_list_to_json record.evidence_refs);
      ("cleared_at", string_option_to_json record.cleared_at);
      ("cleared_by", string_option_to_json record.cleared_by);
      ( "clear_idempotency_key",
        string_option_to_json record.clear_idempotency_key );
    ]

let record_of_yojson json =
  try
    let status =
      json |> U.member "status" |> U.to_string |> status_of_string
    in
    match status with
    | None -> None
    | Some status ->
        Some
          {
            version =
              (json |> U.member "version" |> U.to_int_option
               |> Option.value ~default:record_version);
            keeper_name = json |> U.member "keeper_name" |> U.to_string;
            blocker_class = json |> U.member "blocker_class" |> U.to_string;
            summary = json |> U.member "summary" |> U.to_string;
            failure_reason =
              json |> U.member "failure_reason" |> U.to_string_option;
            trace_id = json |> U.member "trace_id" |> U.to_string_option;
            generation = json |> U.member "generation" |> U.to_int_option;
            committed_tools =
              (match json |> U.member "committed_tools" with
               | `List xs ->
                   xs
                   |> List.filter_map (function
                        | `String value when String.trim value <> "" -> Some value
                        | _ -> None)
               | _ -> []);
            opened_at = json |> U.member "opened_at" |> U.to_string;
            updated_at = json |> U.member "updated_at" |> U.to_string;
            status;
            resolution = json |> U.member "resolution" |> U.to_string_option;
            evidence_refs =
              (match json |> U.member "evidence_refs" with
               | `List xs ->
                   xs
                   |> List.filter_map (function
                        | `String value when String.trim value <> "" -> Some value
                        | _ -> None)
               | _ -> []);
            cleared_at = json |> U.member "cleared_at" |> U.to_string_option;
            cleared_by = json |> U.member "cleared_by" |> U.to_string_option;
            clear_idempotency_key =
              json |> U.member "clear_idempotency_key" |> U.to_string_option;
          }
  with U.Type_error _ | Yojson.Json_error _ | Failure _ -> None

let read (config : Room.config) keeper_name =
  match Room_utils.read_json_opt config (record_path config keeper_name) with
  | Some json -> record_of_yojson json
  | None -> None

let pending_record config keeper_name =
  match read config keeper_name with
  | Some ({ status = Pending; _ } as record) -> Some record
  | _ -> None

let is_pending config keeper_name =
  Option.is_some (pending_record config keeper_name)

let cache_key config keeper_name =
  match read config keeper_name with
  | None -> "none"
  | Some record ->
      String.concat "|"
        [
          status_to_string record.status;
          record.updated_at;
          record.blocker_class;
        ]

let write_record config record =
  Room_utils.write_json config (record_path config record.keeper_name)
    (record_to_yojson record)

let open_pending config ~keeper_name ~blocker_class ~summary ~failure_reason
    ~trace_id ~generation ~committed_tools =
  let opened_at =
    match pending_record config keeper_name with
    | Some record -> record.opened_at
    | None -> now_iso ()
  in
  let record =
    {
      version = record_version;
      keeper_name;
      blocker_class;
      summary;
      failure_reason;
      trace_id;
      generation;
      committed_tools;
      opened_at;
      updated_at = now_iso ();
      status = Pending;
      resolution = None;
      evidence_refs = [];
      cleared_at = None;
      cleared_by = None;
      clear_idempotency_key = None;
    }
  in
  write_record config record;
  record

let clear config ~keeper_name ~actor ~resolution ~evidence_refs ~idempotency_key =
  match read config keeper_name with
  | None -> No_record
  | Some ({ status = Cleared; _ } as record) -> Already_cleared record
  | Some record ->
      let updated =
        {
          record with
          updated_at = now_iso ();
          status = Cleared;
          resolution = Some resolution;
          evidence_refs;
          cleared_at = Some (now_iso ());
          cleared_by = Some actor;
          clear_idempotency_key = idempotency_key;
        }
      in
      write_record config updated;
      Cleared_record updated
