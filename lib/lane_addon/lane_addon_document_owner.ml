type t = Pending of {keeper:string; prior:string option; proposed:string} | Owned of string
  | Reassigned of {keeper:string; revision:string}
let ( let* ) = Result.bind
let protect f = try f () with
  | Sys_error message -> Error message
  | Unix.Unix_error (error, call, _) -> Error (call ^ ": " ^ Unix.error_message error)
  | Yojson.Json_error message -> Error message
let canonical path = Filename.concat (Unix.realpath (Filename.dirname path)) (Filename.basename path)
let identity ~root ~source_path =
  let root = canonical root and source_path = canonical source_path in
  let path = Filename.concat root (Filename.concat "declaration-owners"
    (Lane_addon_store.digest source_path ^ ".jsonl")) in
  root, source_path, path
let keeper = function Pending p -> p.keeper | Owned keeper -> keeper | Reassigned p -> p.keeper
let permits state ~keeper:caller ~source_revision =
  String.equal (keeper state) caller && match state with
    | Owned _ -> true
    | Reassigned p -> p.revision = source_revision
    | Pending p -> p.prior = Some source_revision || p.proposed = source_revision
let digest = function
  | `String value when String.length value = 64
      && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) value -> Ok value
  | _ -> Error "invalid declaration ownership source revision"
let encode ~root ~source_path state =
  let kind, prior, proposed = match state with
    | Owned _ -> "owned", `Null, `Null
    | Reassigned p -> "reassigned", `Null, `String p.revision
    | Pending p -> "pending", Option.fold ~none:`Null ~some:(fun value -> `String value) p.prior, `String p.proposed in
  Yojson.Safe.to_string (`Assoc ["root",`String root; "source_path",`String source_path;
    "keeper",`String (keeper state); "kind",`String kind; "prior",prior; "proposed",proposed]) ^ "\n"
let decode ~root ~source_path bytes =
  let rec loop previous = function
    | [""] -> Ok previous
    | [] -> Error "incomplete declaration ownership journal"
    | row :: rest ->
        let* state = match Yojson.Safe.from_string row with
          | `Assoc fields when List.sort String.compare (List.map fst fields)
              = ["keeper";"kind";"prior";"proposed";"root";"source_path"]
              && List.assoc "root" fields = `String root
              && List.assoc "source_path" fields = `String source_path ->
              (match List.assoc "keeper" fields, List.assoc "kind" fields,
                     List.assoc "prior" fields, List.assoc "proposed" fields with
               | `String keeper, `String "owned", `Null, `Null when String.trim keeper <> "" -> Ok (Owned keeper)
               | `String keeper, `String "reassigned", `Null, revision when String.trim keeper <> "" ->
                   let* revision = digest revision in Ok (Reassigned {keeper;revision})
               | `String keeper, `String "pending", prior, proposed when String.trim keeper <> "" ->
                   let* proposed = digest proposed in
                   let* prior = match prior with `Null -> Ok None | value -> Result.map Option.some (digest value) in
                   Ok (Pending {keeper;prior;proposed})
               | _ -> Error "invalid declaration ownership record")
          | _ -> Error "declaration ownership identity mismatch" in
        let* () = match previous, state with
          | None, Pending _ -> Ok ()
          | Some _, Reassigned _ -> Ok ()
          | Some before, after when String.equal (keeper before) (keeper after) ->
              (match before, after with Owned _, Pending _ -> Error "declaration ownership regressed" | _ -> Ok ())
          | _ -> Error "declaration ownership changed without authority" in
        loop (Some state) rest in
  if bytes = "" then Ok None else loop None (String.split_on_char '\n' bytes)
let cleanup failure = Fs_compat.private_jsonl_operation_failure_to_string failure
let read ~root ~source_path = protect (fun () ->
  let root, source_path, path = identity ~root ~source_path in
  match Fs_compat.read_private_jsonl_rows_locked_result path with
  | Fs_compat.Private_file_succeeded Fs_compat.Private_jsonl_rows.Rows_missing -> Ok None
  | Private_file_succeeded (Rows_present {rows;rows_end;end_offset}) ->
      if rows_end <> end_offset then Error "incomplete declaration ownership journal"
      else decode ~root ~source_path rows
  | Private_file_failed error -> Error (Fs_compat.Private_jsonl_rows.error_to_string error)
  | Private_file_succeeded_with_cleanup_failure {cleanup_failure;_}
  | Private_file_failed_with_cleanup_failure {cleanup_failure;_} -> Error (cleanup cleanup_failure))
let update ~root ~source_path decide = protect (fun () ->
  let root, source_path, path = identity ~root ~source_path in
  let transaction = Fs_compat.update_private_file_durable_locked_result path (fun bytes ->
    match decode ~root ~source_path bytes with
    | Error message -> None, Error message
    | Ok previous -> match decide previous with
        | Error message -> None, Error message
        | Ok None -> None, Ok ()
        | Ok (Some state) -> Some (encode ~root ~source_path state), Ok ()) in
  match transaction with
  | Fs_compat.Private_file_succeeded result -> result
  | Private_file_failed error -> Error (Fs_compat.durable_append_error_to_string error)
  | Private_file_succeeded_with_cleanup_failure {cleanup_failure;_}
  | Private_file_failed_with_cleanup_failure {cleanup_failure;_} -> Error (cleanup cleanup_failure))
let prepare ~root ~source_path ~keeper:caller ~prior_revision ~proposed_revision =
  protect (fun () ->
  Fs_compat.mkdir_p (Filename.dirname source_path);
  update ~root ~source_path (function
    | Some (Owned owner) when String.equal owner caller -> Ok None
    | None -> Ok (Some (Pending {keeper=caller;prior=prior_revision;proposed=proposed_revision}))
    | Some (Pending p) when String.equal p.keeper caller
        && (prior_revision = None || Option.fold ~none:false ~some:(fun revision -> permits (Pending p)
              ~keeper:caller ~source_revision:revision) prior_revision) ->
        Ok (Some (Pending {keeper=caller;prior=prior_revision;proposed=proposed_revision}))
    | Some _ -> Error "declaration is owned by another caller or admission is unconfirmed"))
let complete ~root ~source_path ~keeper:caller ~source_revision =
  update ~root ~source_path (function
    | Some (Owned owner) when String.equal owner caller -> Ok None
    | Some (Pending p) when String.equal p.keeper caller && p.proposed = source_revision ->
        Ok (Some (Owned caller))
    | Some (Reassigned p) when String.equal p.keeper caller && p.revision = source_revision ->
        Ok (Some (Owned caller))
    | None | Some _ -> Error "declaration ownership has no matching pending admission")
let reassign ~root ~source_path ~keeper:caller ~source_revision =
  update ~root ~source_path (function
    | None -> Ok (Some (Pending {keeper=caller;prior=Some source_revision;proposed=source_revision}))
    | Some (Owned owner) when String.equal owner caller -> Ok None
    | Some _ -> Ok (Some (Reassigned {keeper=caller;revision=source_revision})))
