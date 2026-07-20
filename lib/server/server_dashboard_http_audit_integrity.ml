(** Audit-integrity dashboard HTTP JSON helper.

    Runs [Shared_audit.Store.verify] over the per-keeper resilience audit
    logs and produces a read-only snapshot for the
    /api/v1/dashboard/audit-integrity endpoint.

    Data sources:
    - [<base_path>/.masc/resilience_audit/<keeper>/] — the write path is
      owned by [Keeper_turn_runtime_budget.resilience_audit_dir]; this
      module only reads that layout.
    - [Resilience.Keeper_bridge.masc_resilience_enabled] for the feature
      flag state, so operators can distinguish "feature off" from
      "no broken chains".

    A keeper whose log cannot be read or parsed is reported as a failed
    verification (not skipped): unreadable audit evidence is itself an
    integrity signal. *)

type keeper_report =
  { keeper_id : string
  ; entries : int
  ; ok : bool
  ; broken_at : int option
  ; detail : string option
  }

let audit_root ~base_path =
  Filename.concat (Config_dir_resolver.masc_root ~base_path) "resilience_audit"
;;

let list_keeper_ids root =
  if not (Sys.file_exists root)
  then []
  else if not (Sys.is_directory root)
  then []
  else
    Sys.readdir root
    |> Array.to_list
    |> List.filter (fun name -> Sys.is_directory (Filename.concat root name))
    |> List.sort String.compare
;;

let verify_keeper ~root keeper_id =
  let base_dir = Filename.concat root keeper_id in
  try
    let store = Shared_audit.Store.create ~base_dir in
    let report = Shared_audit.Store.verify store in
    match report.failure with
    | None ->
      { keeper_id
      ; entries = report.entries_checked
      ; ok = true
      ; broken_at = None
      ; detail = None
      }
    | Some (idx, reason) ->
      { keeper_id
      ; entries = report.entries_checked
      ; ok = false
      ; broken_at = Some idx
      ; detail = Some reason
      }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Shared_audit.Store.Corrupt_jsonl { path; line_number; detail } ->
    { keeper_id
    ; entries = 0
    ; ok = false
    ; broken_at = None
    ; detail =
        Some (Printf.sprintf "corrupt audit JSONL %s:%d: %s" path line_number detail)
    }
  | exn ->
    Log.Dashboard.warn
      "[audit_integrity] verify failed for keeper %s: %s"
      keeper_id
      (Printexc.to_string exn);
    { keeper_id
    ; entries = 0
    ; ok = false
    ; broken_at = None
    ; detail = Some (Printexc.to_string exn)
    }
;;

let keeper_report_to_json r =
  `Assoc
    [ "keeper_id", `String r.keeper_id
    ; "entries", `Int r.entries
    ; "ok", `Bool r.ok
    ; "broken_at", Option.fold ~none:`Null ~some:(fun idx -> `Int idx) r.broken_at
    ; "detail", Option.fold ~none:`Null ~some:(fun d -> `String d) r.detail
    ]
;;

let audit_integrity_http_json ~base_path : Yojson.Safe.t =
  (* NDT-OK: diagnostic snapshot timestamp only; verification never
     branches on the wall clock. *)
  let now = Unix.gettimeofday () in
  let root = audit_root ~base_path in
  let reports =
    list_keeper_ids root
    |> List.map (verify_keeper ~root)
    (* Failures first so broken chains surface at the top. *)
    |> List.sort (fun a b ->
      match a.ok, b.ok with
      | false, true -> -1
      | true, false -> 1
      | _ -> String.compare a.keeper_id b.keeper_id)
  in
  let failed = List.filter (fun r -> not r.ok) reports in
  `Assoc
    [ "generated_at", `Float now
    ; ( "resilience_enabled"
      , `Bool (Resilience.Keeper_bridge.masc_resilience_enabled ()) )
    ; "keepers", `List (List.map keeper_report_to_json reports)
    ; ( "totals"
      , `Assoc
          [ "keepers", `Int (List.length reports)
          ; ( "entries"
            , `Int (List.fold_left (fun acc r -> acc + r.entries) 0 reports) )
          ; "ok", `Int (List.length reports - List.length failed)
          ; "failed", `Int (List.length failed)
          ] )
    ]
;;
