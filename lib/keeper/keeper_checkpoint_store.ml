(** Keeper_checkpoint_store — checkpoint file I/O.

    Handles saving, loading, listing, and pruning checkpoint JSON files
    within a session directory. Separated from [Keeper_working_context]
    so that file I/O concerns do not mix with context types and
    pure operations.

    @since keeper-ctx-split *)

open Printf

(* ================================================================ *)
(* Checkpoint File Conventions                                        *)
(* ================================================================ *)

let checkpoint_prefix = "ckpt-"
let checkpoint_suffix = ".json"

let is_checkpoint_file (filename : string) : bool =
  let len = String.length filename in
  len > String.length checkpoint_prefix + String.length checkpoint_suffix
  && String.sub filename 0 (String.length checkpoint_prefix) = checkpoint_prefix
  && String.sub filename (len - String.length checkpoint_suffix)
       (String.length checkpoint_suffix) = checkpoint_suffix

(* ================================================================ *)
(* List                                                               *)
(* ================================================================ *)

let list_checkpoints ~(session_dir : string) : string list =
  if not (Fs_compat.file_exists session_dir) then []
  else
    Sys.readdir session_dir
    |> Array.to_list
    |> List.filter is_checkpoint_file
    |> List.sort (fun a b -> compare b a)

(** Maximum number of checkpoint files to retain per session.
    Only the latest N are kept; older ones are deleted after each save. *)
let max_checkpoints_retained = 3

(* ================================================================ *)
(* Prune                                                              *)
(* ================================================================ *)

let prune ~(session_dir : string) ~(keep : int) : int =
  let files = list_checkpoints ~session_dir in
  if List.length files <= keep then 0
  else
    let to_remove = List.filteri (fun i _ -> i >= keep) files in
    List.iter (fun filename ->
      let path = Filename.concat session_dir filename in
      (try Sys.remove path
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Log.Keeper.warn "checkpoint cleanup failed for %s: %s"
           path (Printexc.to_string exn);
         Prometheus.inc_counter
           Prometheus.metric_keeper_checkpoint_failures
           ~labels:[("site", "cleanup")]
           ()))
      to_remove;
    List.length to_remove

(* ================================================================ *)
(* Save                                                               *)
(* ================================================================ *)

let save
    ~(session_dir : string)
    (ckpt : Keeper_types.checkpoint) : unit =
  let path = Filename.concat session_dir
    (sprintf "%s%s" ckpt.checkpoint_id checkpoint_suffix) in
  let context_json =
    try Yojson.Safe.from_string ckpt.serialized
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> `String ckpt.serialized
  in
  let json = `Assoc [
    ("checkpoint_id", `String ckpt.checkpoint_id);
    ("timestamp", `Float ckpt.timestamp);
    ("generation", `Int ckpt.generation);
    ("message_count", `Int ckpt.message_count);
    ("token_count", `Int ckpt.token_count);
    ("context", context_json);
  ] in
  let content = Yojson.Safe.to_string json in
  match Keeper_fs.save_atomic path content with
  | Ok () ->
    (* Auto-prune old checkpoints after each save *)
    ignore (prune ~session_dir ~keep:max_checkpoints_retained)
  | Error msg ->
    Log.Keeper.warn "save_checkpoint failed for %s: %s" path msg;
    Prometheus.inc_counter
      Prometheus.metric_keeper_checkpoint_failures
      ~labels:[("site", "save")]
      ()

(* ================================================================ *)
(* Load Latest                                                        *)
(* ================================================================ *)

let parse_checkpoint_file (path : string) : Keeper_types.checkpoint =
  let content = Fs_compat.load_file path in
  let json =
    content
    |> Inference_utils.sanitize_text_utf8
    |> Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  let serialized =
    match json |> member "context" with
    | `Null | exception Yojson.Safe.Util.Type_error _ ->
        json |> member "serialized" |> to_string
    | ctx -> Yojson.Safe.to_string ctx
  in
  {
    Keeper_types.checkpoint_id =
      json |> member "checkpoint_id" |> to_string;
    timestamp = json |> member "timestamp" |> to_number;
    generation = json |> member "generation" |> to_int;
    message_count = json |> member "message_count" |> to_int;
    token_count = json |> member "token_count" |> to_int;
    serialized;
  }

let load_latest ~(session_dir : string) : Keeper_types.checkpoint option =
  match list_checkpoints ~session_dir with
  | [] -> None
  | latest :: _ ->
    let path = Filename.concat session_dir latest in
    (try Some (parse_checkpoint_file path)
     with Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.warn "malformed checkpoint ignored in %s: %s"
         path (Printexc.to_string exn);
       Prometheus.inc_counter
         Prometheus.metric_keeper_checkpoint_failures
         ~labels:[("site", "malformed_load")]
         ();
       None)

(* ================================================================ *)
(* OAS Checkpoint Compatibility                                      *)
(* ================================================================ *)

let oas_checkpoint_path ~(session_dir : string) ~(session_id : string) =
  Filename.concat session_dir (session_id ^ ".json")

let oas_history_prefix = "oas-snapshot-"
let oas_history_suffix = ".json"

let is_oas_history_file (filename : string) : bool =
  let len = String.length filename in
  len > String.length oas_history_prefix + String.length oas_history_suffix
  && String.sub filename 0 (String.length oas_history_prefix) = oas_history_prefix
  && String.sub filename (len - String.length oas_history_suffix)
       (String.length oas_history_suffix) = oas_history_suffix

let list_oas_history_files ~(session_dir : string) : string list =
  if not (Fs_compat.file_exists session_dir) then []
  else
    Sys.readdir session_dir
    |> Array.to_list
    |> List.filter is_oas_history_file
    |> List.sort (fun a b -> compare b a)

let max_oas_history_retained = 12

let oas_history_path ~(session_dir : string) ~(snapshot_id : string) =
  Filename.concat session_dir snapshot_id

let oas_history_snapshot_id_of_checkpoint (ckpt : Agent_sdk.Checkpoint.t) : string =
  let generation =
    match ckpt.working_context with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "keeper_generation" fields with
        | Some (`Int n) -> n
        | Some (`Intlit raw) -> Option.value ~default:0 (int_of_string_opt raw)
        | _ -> 0)
    | _ -> 0
  in
  let created_ms = max 0 (int_of_float (ckpt.created_at *. 1000.0)) in
  Printf.sprintf "%s%013d-g%d%s"
    oas_history_prefix created_ms generation oas_history_suffix

let save_oas_history ~(session_dir : string) (ckpt : Agent_sdk.Checkpoint.t) : unit =
  let snapshot_id = oas_history_snapshot_id_of_checkpoint ckpt in
  match Keeper_fs.save_atomic
    (oas_history_path ~session_dir ~snapshot_id)
    (Agent_sdk.Checkpoint.to_string ckpt) with
  | Ok () ->
    let files = list_oas_history_files ~session_dir in
    if List.length files > max_oas_history_retained then
      files
      |> List.filteri (fun index _ -> index >= max_oas_history_retained)
      |> List.iter (fun filename ->
           let path = oas_history_path ~session_dir ~snapshot_id:filename in
           try Sys.remove path with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               Log.Keeper.warn "OAS snapshot cleanup failed for %s: %s"
                 path (Printexc.to_string exn);
               Prometheus.inc_counter
                 Prometheus.metric_keeper_checkpoint_failures
                 ~labels:[("site", "oas_cleanup")]
                 ())
  | Error msg ->
    Log.Keeper.warn "save_oas_history failed for %s: %s" snapshot_id msg;
    Prometheus.inc_counter
      Prometheus.metric_keeper_checkpoint_failures
      ~labels:[("site", "oas_save")]
      ()

let delete_oas_history_files ~(session_dir : string) ~(snapshot_ids : string list)
    : string list * string list =
  List.fold_left
    (fun (deleted, missing) snapshot_id ->
      let path = oas_history_path ~session_dir ~snapshot_id in
      if Fs_compat.file_exists path then (
        try
          Sys.remove path;
          (snapshot_id :: deleted, missing)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Log.Keeper.warn "OAS snapshot delete failed for %s: %s"
              path (Printexc.to_string exn);
            Prometheus.inc_counter
              Prometheus.metric_keeper_checkpoint_failures
              ~labels:[("site", "oas_delete")]
              ();
            (deleted, snapshot_id :: missing))
      else
        (deleted, snapshot_id :: missing))
    ([], [])
    snapshot_ids
  |> fun (deleted, missing) -> (List.rev deleted, List.rev missing)

let save_oas ~(session_dir : string) (ckpt : Agent_sdk.Checkpoint.t)
  : (unit, string) result =
  let fallback () =
    match Keeper_fs.save_atomic
      (oas_checkpoint_path ~session_dir ~session_id:ckpt.session_id)
      (Agent_sdk.Checkpoint.to_string ckpt) with
    | Ok () ->
      (try save_oas_history ~session_dir ckpt with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Keeper.warn "OAS snapshot archive write failed for %s: %s"
             ckpt.session_id (Printexc.to_string exn);
           Prometheus.inc_counter
             Prometheus.metric_keeper_checkpoint_failures
             ~labels:[("site", "oas_archive_fallback")]
             ());
      Ok ()
    | Error msg -> Error msg
  in
  try
    ignore (Keeper_fs.ensure_dir session_dir);
    match Fs_compat.get_fs_opt () with
    | Some fs when Eio_guard.is_ready () ->
        let dir = Eio.Path.(fs / session_dir) in
        (match Agent_sdk.Checkpoint_store.create dir with
         | Ok store -> (
             match Agent_sdk.Checkpoint_store.save store ckpt with
             | Ok () ->
                 (try save_oas_history ~session_dir ckpt with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                      Log.Keeper.warn "OAS snapshot archive write failed for %s: %s"
                        ckpt.session_id (Printexc.to_string exn);
                      Prometheus.inc_counter
                        Prometheus.metric_keeper_checkpoint_failures
                        ~labels:[("site", "oas_archive_primary")]
                        ());
                 Ok ()
             | Error err -> Error (Agent_sdk.Error.to_string err))
         | Error err -> Error (Agent_sdk.Error.to_string err))
    | Some _ | None ->
        fallback ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printf.sprintf "save_oas: %s" (Printexc.to_string exn))

(* Delta Checkpoint Shadow-Apply removed: Agent_sdk.Checkpoint.delta
   type was removed upstream. Functions had zero callers. *)

type checkpoint_load_error =
  | Not_found
  | Store_error of string
  | Parse_error of string
  | Io_error of string
  (** Catch-all for SDK errors outside the Io / Serialization families
      (Api / Agent / Mcp / Config / Orchestration / Internal).
      Distinct from Io_error so observers can tell a local
      checkpoint-store I/O failure apart from an SDK-level failure that
      surfaced during a load. (#8605 family) *)
  | Sdk_other_error of string

(* Checkpoint-load failures classify as [Not_found] only when the
   underlying SDK error is genuinely "this file does not exist on first
   boot" — any other I/O problem should stay [Io_error] so we keep the
   detail in the error log.

   The matching surface is fragile because [Agent_sdk] serializes
   filesystem failures via [Printexc.to_string] inside
   [FileOpFailed.detail] (see oas/lib/fs_result.ml), so we pattern-match
   on the rendered strings of every exception constructor the OAS
   wrapper produces:

   - [Eio.Io (Fs Not_found _)] → "Eio.Io Fs Not_found Unix_error ..."
   - [Unix.Unix_error (ENOENT, _, _)] → "Unix_error(ENOENT, ...)"
   - [Sys_error "..."] → "No such file or directory: ..."
   - legacy masc-mcp path that stored just "no_such_file" as detail

   The [has_substring] fallback catches the canonical ENOENT phrase
   anywhere in the rendered string so that wrapper layers that prepend
   context (e.g. [sprintf "load %s: %s" path ...]) still classify
   correctly. *)
let is_not_found_detail (detail : string) : bool =
  let d = String.lowercase_ascii detail in
  (* Local to keep [Keeper_checkpoint_store] surface free of a generic
     string helper — this module has no .mli so every top-level [let]
     is exported. *)
  let has_substring haystack needle =
    let hl = String.length haystack and nl = String.length needle in
    if nl = 0 then true
    else if nl > hl then false
    else
      let rec loop i =
        if i + nl > hl then false
        else if String.sub haystack i nl = needle then true
        else loop (i + 1)
      in
      loop 0
  in
  String.starts_with ~prefix:"no_such_file" d  (* legacy masc-mcp path *)
  || String.starts_with ~prefix:"no such file" d
  || String.starts_with ~prefix:"unix_error (enoent" d  (* POSIX *)
  || String.starts_with ~prefix:"eio.io fs not_found" d  (* Eio.Io (Fs Not_found _) *)
  || has_substring d "no such file or directory"

(* #8605 family: exhaustive on Agent_sdk.Error.sdk_error top-level
   variants. The previous wildcard collapsed Api / Agent / Mcp / Config
   / Orchestration / A2a / Internal errors into Io_error, hiding
   non-IO failures from the dashboard. The wildcards on Io _ and
   Serialization _ remain narrow (one level deep) so future inner
   variants land in the semantically correct category, but a future
   top-level sdk_error variant becomes a build error and forces a
   deliberate routing decision. *)
let classify_sdk_error (e : Agent_sdk.Error.sdk_error) : checkpoint_load_error =
  match e with
  | Io (FileOpFailed r) ->
      if is_not_found_detail r.detail then Not_found
      else Io_error (sprintf "file %s failed on %s: %s" r.op r.path r.detail)
  | Io (ValidationFailed r) -> Store_error r.detail
  | Serialization (JsonParseError r) -> Parse_error r.detail
  | Serialization (VersionMismatch r) ->
      Parse_error (sprintf "version mismatch: expected %d, got %d" r.expected r.got)
  | Serialization (UnknownVariant r) ->
      Parse_error (sprintf "unknown variant %s: %s" r.type_name r.value)
  | Api _ | Agent _ | Mcp _ | Config _
  | Orchestration _ | A2a _ | Internal _ ->
      Sdk_other_error (Agent_sdk.Error.to_string e)

let result_all items =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | Ok item :: rest -> loop (item :: acc) rest
    | Error e :: _ -> Error e
  in
  loop [] items

let content_block_of_json_strict json =
  try
    match Agent_sdk.Api.content_block_of_json json with
    | Some block -> Ok block
    | None ->
        let open Yojson.Safe.Util in
        let block_type =
          json |> member "type" |> to_string_option |> Option.value ~default:"<missing>"
        in
        Error
          (Agent_sdk.Error.Serialization
             (JsonParseError
                {
                  detail =
                    Printf.sprintf "Unknown content block type: %s" block_type;
                }))
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
      Error
        (Agent_sdk.Error.Serialization
           (JsonParseError
              { detail = Printf.sprintf "Invalid content block: %s" msg }))
  | Yojson.Json_error msg ->
      Error
        (Agent_sdk.Error.Serialization
           (JsonParseError
              { detail = Printf.sprintf "Invalid content block: %s" msg }))
  | Failure msg ->
      Error
        (Agent_sdk.Error.Serialization
           (JsonParseError
              { detail = Printf.sprintf "Invalid content block: %s" msg }))

let role_of_string_compat raw =
  match String.lowercase_ascii (String.trim raw) with
  | "system" -> Ok Agent_sdk.Types.System
  | "user" -> Ok Agent_sdk.Types.User
  | "assistant" -> Ok Agent_sdk.Types.Assistant
  | "tool" -> Ok Agent_sdk.Types.Tool
  | other ->
      Error
        (Agent_sdk.Error.Serialization
           (UnknownVariant { type_name = "role"; value = other }))

let message_of_json_compat json =
  let open Yojson.Safe.Util in
  try
    let role = json |> member "role" |> to_string |> role_of_string_compat in
    let content =
      json |> member "content" |> to_list
      |> List.map content_block_of_json_strict
      |> result_all
    in
    match role, content with
    | Ok role, Ok content ->
        Ok
          {
            Agent_sdk.Types.role;
            content;
            name = json |> member "name" |> to_string_option;
            tool_call_id = json |> member "tool_call_id" |> to_string_option;
            metadata = [];
          }
    | Error e, _ -> Error e
    | _, Error e -> Error e
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
      Error
        (Agent_sdk.Error.Serialization
           (JsonParseError
              { detail = Printf.sprintf "Invalid checkpoint message: %s" msg }))
  | Yojson.Json_error msg ->
      Error
        (Agent_sdk.Error.Serialization
           (JsonParseError
              { detail = Printf.sprintf "Invalid checkpoint message: %s" msg }))

let normalize_checkpoint_json_for_sdk json =
  let normalize_message = function
    | `Assoc fields ->
        `Assoc
          (List.map
             (function
               | "role", `String ("assistant" | "user" as role) ->
                   ("role", `String role)
               | "role", `String _ ->
                   ("role", `String "assistant")
               | field -> field)
             fields)
    | other -> other
  in
  match json with
  | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "messages", `List messages ->
                 ("messages", `List (List.map normalize_message messages))
             | field -> field)
           fields)
  | other -> other

let checkpoint_of_json_compat json =
  let open Yojson.Safe.Util in
  try
    let messages =
      json |> member "messages" |> to_list
      |> List.map message_of_json_compat
      |> result_all
    in
    match messages with
    | Error e -> Error e
    | Ok messages -> (
        match Agent_sdk.Checkpoint.of_json (normalize_checkpoint_json_for_sdk json) with
        | Ok checkpoint -> Ok { checkpoint with messages }
        | Error e -> Error e)
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
      Error
        (Agent_sdk.Error.Serialization
           (JsonParseError
              { detail = Printf.sprintf "Checkpoint.of_json compat: %s" msg }))
  | Yojson.Json_error msg ->
      Error
        (Agent_sdk.Error.Serialization
           (JsonParseError
              { detail = Printf.sprintf "Checkpoint.of_json compat: %s" msg }))

let checkpoint_of_string_compat raw =
  match Agent_sdk.Checkpoint.of_string raw with
  | Ok checkpoint -> Ok checkpoint
  | Error _ ->
      let json =
        raw
        |> Inference_utils.sanitize_text_utf8
        |> Yojson.Safe.from_string
      in
      checkpoint_of_json_compat json

let load_oas_history_file ~(session_dir : string) ~(snapshot_id : string) :
    (Agent_sdk.Checkpoint.t, checkpoint_load_error) result =
  let path = oas_history_path ~session_dir ~snapshot_id in
  if Fs_compat.file_exists path then
    try
      match checkpoint_of_string_compat (Fs_compat.load_file path) with
      | Ok ckpt -> Ok ckpt
      | Error e -> Error (classify_sdk_error e)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Error (Io_error (Printexc.to_string exn))
  else Error Not_found

let load_oas ~(session_dir : string) ~(session_id : string) :
    (Agent_sdk.Checkpoint.t, checkpoint_load_error) result =
  let fallback () =
    let path = oas_checkpoint_path ~session_dir ~session_id in
    if Fs_compat.file_exists path then
      try
        match checkpoint_of_string_compat (Fs_compat.load_file path) with
        | Ok ckpt -> Ok ckpt
        | Error e -> Error (classify_sdk_error e)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Error (Io_error (Printexc.to_string exn))
    else Error Not_found
  in
  match Fs_compat.get_fs_opt () with
  | Some fs when Eio_guard.is_ready () ->
      let dir = Eio.Path.(fs / session_dir) in
      (match Agent_sdk.Checkpoint_store.create dir with
       | Ok store -> (
           match Agent_sdk.Checkpoint_store.load store session_id with
           | Ok ckpt -> Ok ckpt
           | Error e -> Error (classify_sdk_error e))
       | Error e -> Error (Store_error (Agent_sdk.Error.to_string e)))
  | Some _ | None ->
      fallback ()
