type t = Pending of {keeper:string; prior:string option; proposed:string; repair:bool}
  | Owned of {keeper:string; revision:string}
  | Reassigned of {keeper:string; revision:string} | Revoked
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
let keeper = function Pending p -> Some p.keeper | Owned p -> Some p.keeper | Reassigned p -> Some p.keeper | Revoked -> None
let permits state ~keeper:caller ~source_revision =
  keeper state = Some caller && match state with
    | Owned p -> p.revision = source_revision
    | Revoked -> false
    | Reassigned p -> p.revision = source_revision
    | Pending p -> p.prior = Some source_revision || p.proposed = source_revision
let repair_permits state ~keeper:caller =
  match state with
  | Owned p -> String.equal p.keeper caller
  | Pending p -> p.repair && String.equal p.keeper caller
  | Reassigned _ | Revoked -> false
let digest = function
  | `String value when String.length value = 64
      && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) value -> Ok value
  | _ -> Error "invalid declaration ownership source revision"
let encode ~root ~source_path state =
  let kind, prior, proposed, repair = match state with
    | Owned p -> "owned", `Null, `String p.revision, false
    | Revoked -> "revoked", `Null, `Null, false
    | Reassigned p -> "reassigned", `Null, `String p.revision, false
    | Pending p -> "pending", Option.fold ~none:`Null ~some:(fun value -> `String value) p.prior,
        `String p.proposed, p.repair in
  Yojson.Safe.to_string (`Assoc ["root",`String root; "source_path",`String source_path;
    "keeper",Option.fold ~none:`Null ~some:(fun keeper -> `String keeper) (keeper state); "kind",`String kind; "prior",prior;
    "proposed",proposed; "repair",`Bool repair]) ^ "\n"
let decode ~root ~source_path bytes =
  let rec loop previous = function
    | [""] -> Ok previous
    | [] -> Error "incomplete declaration ownership journal"
    | row :: rest ->
        let* state = match Yojson.Safe.from_string row with
          | `Assoc fields when List.sort String.compare (List.map fst fields)
              = ["keeper";"kind";"prior";"proposed";"repair";"root";"source_path"]
              && List.assoc "root" fields = `String root
              && List.assoc "source_path" fields = `String source_path ->
              (match List.assoc "keeper" fields, List.assoc "kind" fields,
                     List.assoc "prior" fields, List.assoc "proposed" fields,
                     List.assoc "repair" fields with
               | `Null, `String "revoked", `Null, `Null, `Bool false -> Ok Revoked
               | `String keeper, `String "owned", `Null, revision, `Bool false when String.trim keeper <> "" ->
                   let* revision = digest revision in Ok (Owned {keeper;revision})
               | `String keeper, `String "reassigned", `Null, revision, `Bool false when String.trim keeper <> "" ->
                   let* revision = digest revision in Ok (Reassigned {keeper;revision})
               | `String keeper, `String "pending", prior, proposed, `Bool repair when String.trim keeper <> "" ->
                   let* proposed = digest proposed in
                   let* prior = match prior with `Null -> Ok None | value -> Result.map Option.some (digest value) in
                   Ok (Pending {keeper;prior;proposed;repair})
               | _ -> Error "invalid declaration ownership record")
          | _ -> Error "declaration ownership identity mismatch" in
        let* () = match previous, state with
          | None, Pending p when p.repair -> Error "repair admission has no completed owner"
          | None, Pending _ -> Ok ()
          | Some _, (Reassigned _ | Revoked) -> Ok ()
          | Some Revoked, Pending p when not p.repair -> Ok ()
          | Some (Owned before), Pending after
            when not after.repair || after.prior <> Some before.revision ->
              Error "repair admission lost the admitted prior revision"
          | Some (Pending before), Pending after
            when before.repair <> after.repair
              || (before.repair && before.prior <> after.prior) ->
              Error "repair retry changed its admitted prior revision"
          | Some (Reassigned _ | Revoked), Pending after when after.repair ->
              Error "reassigned ownership cannot become repair authority"
          | Some (Pending before), Owned after when before.proposed <> after.revision ->
              Error "completed ownership does not match the proposed revision"
          | Some (Reassigned before), Owned after when before.revision <> after.revision ->
              Error "completed reassignment does not match the observed revision"
          | Some before, after when keeper before = keeper after -> Ok ()
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
      else Result.map (function Some Revoked -> None | value -> value) (decode ~root ~source_path rows)
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
    | Some (Owned owner) when String.equal owner.keeper caller ->
        Ok (Some (Pending {keeper=caller;prior=Some owner.revision;
          proposed=proposed_revision;repair=true}))
    | None | Some Revoked -> Ok (Some (Pending {keeper=caller;prior=prior_revision;
        proposed=proposed_revision;repair=false}))
    | Some (Pending p) when String.equal p.keeper caller
        && (p.repair || prior_revision = None || Option.fold ~none:false ~some:(fun revision -> permits (Pending p)
              ~keeper:caller ~source_revision:revision) prior_revision) ->
        Ok (Some (Pending {keeper=caller;
          prior=(if p.repair then p.prior else prior_revision);
          proposed=proposed_revision;repair=p.repair}))
    | Some _ -> Error "declaration is owned by another caller or admission is unconfirmed"))
let complete ~root ~source_path ~keeper:caller ~source_revision =
  update ~root ~source_path (function
    | Some (Owned owner) when String.equal owner.keeper caller && owner.revision = source_revision -> Ok None
    | Some (Pending p) when String.equal p.keeper caller && p.proposed = source_revision ->
        Ok (Some (Owned {keeper=caller;revision=source_revision}))
    | Some (Reassigned p) when String.equal p.keeper caller && p.revision = source_revision ->
        Ok (Some (Owned {keeper=caller;revision=source_revision}))
    | None | Some _ -> Error "declaration ownership has no matching pending admission")
let reassign ~root ~source_path ~keeper:caller ~source_revision =
  update ~root ~source_path (function
    | None -> Ok (Some (Pending {keeper=caller;prior=Some source_revision;
        proposed=source_revision;repair=false}))
    | Some (Owned owner) when String.equal owner.keeper caller && owner.revision = source_revision -> Ok None
    | Some _ -> Ok (Some (Reassigned {keeper=caller;revision=source_revision})))

let revoke ~root ~source_path = update ~root ~source_path (function
  | None | Some Revoked -> Ok None
  | Some _ -> Ok (Some Revoked))
