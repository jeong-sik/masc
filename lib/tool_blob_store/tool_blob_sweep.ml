module String_set = Set_util.StringSet

type previous_now_live =
  { rewritten : int
  ; read_only : int
  ; untouched : int
  }

type previous_comparison =
  { previous_deletable : int
  ; previous_deletable_read : int
  ; now_live : previous_now_live
  }

type previous =
  | No_previous_record
  | Previous_record_invalid of
      { line : int
      ; detail : string
      }
  | Compared_with_previous of previous_comparison

type report =
  { scan_started_at : float
  ; scan_seconds : float
  ; live_digests : int
  ; blobs : int
  ; candidates : int
  ; deletable : int
  ; deletable_bytes : int
  ; deleted : int
  ; deleted_bytes : int
  ; delete_failures : int
  ; unstatable : int
  ; unclassified : string list
  ; malformed_warnings : Tool_blob_maintenance.malformed_reference_warning list
  ; previous : previous
  ; touches : Tool_blob_store.touch_counts
  }

type error =
  | Scan_failed of Tool_blob_maintenance.error
  | Listing_failed of Tool_blob_store.list_error
  | Record_unreadable of
      { path : string
      ; detail : string
      }
  | Record_write_failed of
      { path : string
      ; detail : string
      ; deleted : int
      ; deleted_bytes : int
      ; delete_failures : int
      }
  | Marker_failed of
      { path : string
      ; detail : string
      }

let error_to_string = function
  | Scan_failed error -> "durable reference scan: " ^ Tool_blob_maintenance.error_to_string error
  | Listing_failed { path; reason } -> Printf.sprintf "blob listing path=%s: %s" path reason
  | Record_unreadable { path; detail } ->
    Printf.sprintf "candidate record unreadable path=%s: %s" path detail
  | Record_write_failed { path; detail; deleted; deleted_bytes; delete_failures } ->
    if deleted > 0 || delete_failures > 0
    then
      Printf.sprintf
        "candidate record write path=%s (after deleted=%d deleted_bytes=%d delete_failures=%d): %s"
        path
        deleted
        deleted_bytes
        delete_failures
        detail
    else Printf.sprintf "candidate record write path=%s: %s" path detail
  | Marker_failed { path; detail } -> Printf.sprintf "scan marker path=%s: %s" path detail
;;

let report_to_string report =
  let previous =
    match report.previous with
    | No_previous_record -> "previous=none"
    | Previous_record_invalid { line; detail } ->
      Printf.sprintf "previous=invalid line=%d detail=%S" line detail
    | Compared_with_previous previous ->
      Printf.sprintf
        "previous_deletable=%d previous_deletable_read=%d now_live_rewritten=%d \
         now_live_read_only=%d now_live_untouched=%d"
        previous.previous_deletable
        previous.previous_deletable_read
        previous.now_live.rewritten
        previous.now_live.read_only
        previous.now_live.untouched
  in
  Printf.sprintf
    "scan_seconds=%.1f live_digests=%d blobs=%d candidates=%d deletable=%d \
     deletable_bytes=%d deleted=%d deleted_bytes=%d delete_failures=%d \
     unstatable=%d unclassified=%d malformed_warnings=%d %s touched_current=%d \
     touched_previous=%d touched_current_evicted=%b touched_previous_evicted=%b"
    report.scan_seconds
    report.live_digests
    report.blobs
    report.candidates
    report.deletable
    report.deletable_bytes
    report.deleted
    report.deleted_bytes
    report.delete_failures
    report.unstatable
    (List.length report.unclassified)
    (List.length report.malformed_warnings)
    previous
    report.touches.Tool_blob_store.current_addresses
    report.touches.previous_addresses
    report.touches.current_evicted
    report.touches.previous_evicted
;;

let maintenance_dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) Tool_blob_maintenance.dirname
;;

let record_path ~base_path = Filename.concat (maintenance_dir ~base_path) "candidates-v2"
let marker_path ~base_path = Filename.concat (maintenance_dir ~base_path) "scan-opened"

(* {1 Schedule} *)

type schedule =
  | Due
  | Next_at of float

let marker_mtime ~base_path =
  let path = marker_path ~base_path in
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_REG; st_mtime; _ } -> Ok (Some st_mtime)
  | { Unix.st_kind = (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK) as kind; _ } ->
    Error (Marker_failed { path; detail = "not a regular file: " ^ Fs_compat.file_kind_to_string kind })
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exception Unix.Unix_error (code, fn, arg) ->
    Error (Marker_failed { path; detail = Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code) })
;;

let schedule ~base_path ~now =
  match marker_mtime ~base_path with
  | Error _ as error -> error
  | Ok None -> Ok Due
  | Ok (Some opened_at) ->
    let next = opened_at +. Masc_time_constants.day in
    if now >= next then Ok Due else Ok (Next_at next)
;;

(* {1 Candidate record} *)

type record =
  { recorded_scan_started_at : float
  ; recorded_candidates : String_set.t
  ; recorded_deletable : String_set.t
  }

let header_json
      ~scan_started_at
      ~candidates
      ~deletable
      ~untouched_live
      ~unclassified
      ~current_evicted
      ~previous_evicted
  =
  `Assoc
    [ "schema_version", `Int 2
    ; "scan_started_at", `Float scan_started_at
    ; "candidates", `Int candidates
    ; "deletable", `Int deletable
    ; "untouched_live", `Int untouched_live
    ; "unclassified", `List (List.map (fun name -> `String name) unclassified)
    ; "current_evicted", `Bool current_evicted
    ; "previous_evicted", `Bool previous_evicted
    ]
;;

type header =
  { scan_started_at : float
  ; candidates : int
  ; deletable : int
  ; untouched_live : int
  ; unclassified : int
  ; current_evicted : bool
  ; previous_evicted : bool
  }

let unclassified_names names =
  List.fold_left
    (fun count name ->
       match count with
       | None -> None
       | Some count ->
         (match name with
          | `String _ -> Some (count + 1)
          | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> None))
    (Some 0)
    names
;;

let header_of_json = function
  | `Assoc
      [ "schema_version", `Int 2
      ; "scan_started_at", `Float scan_started_at
      ; "candidates", `Int candidates
      ; "deletable", `Int deletable
      ; "untouched_live", `Int untouched_live
      ; "unclassified", `List names
      ] ->
    (match unclassified_names names with
     | Some unclassified ->
       Some
         { scan_started_at
         ; candidates
         ; deletable
         ; untouched_live
         ; unclassified
         ; current_evicted = false
         ; previous_evicted = false
         }
     | None -> None)
  | `Assoc
      [ "schema_version", `Int 2
      ; "scan_started_at", `Float scan_started_at
      ; "candidates", `Int candidates
      ; "deletable", `Int deletable
      ; "untouched_live", `Int untouched_live
      ; "unclassified", `List names
      ; "current_evicted", `Bool current_evicted
      ; "previous_evicted", `Bool previous_evicted
      ] ->
    (match unclassified_names names with
     | Some unclassified ->
       Some
         { scan_started_at
         ; candidates
         ; deletable
         ; untouched_live
         ; unclassified
         ; current_evicted
         ; previous_evicted
         }
     | None -> None)
  | _ -> None
;;

type line_kind =
  | Candidate
  | Deletable
  | Untouched_live

let line_kind_of_tag = function
  | 'c' -> Some Candidate
  | 'd' -> Some Deletable
  | 'u' -> Some Untouched_live
  | _ -> None
;;

let tag_of_line_kind = function
  | Candidate -> 'c'
  | Deletable -> 'd'
  | Untouched_live -> 'u'
;;

(* One digest line is a tag, a space and 64 hex digits. *)
let digest_line_length = 66

type tally =
  { candidate_lines : String_set.t
  ; deletable_lines : String_set.t
  ; untouched_lines : int
  }

let add_line kind sha256 tally =
  match kind with
  | Candidate -> { tally with candidate_lines = String_set.add sha256 tally.candidate_lines }
  | Deletable -> { tally with deletable_lines = String_set.add sha256 tally.deletable_lines }
  | Untouched_live -> { tally with untouched_lines = tally.untouched_lines + 1 }
;;

type invalid_record =
  { invalid_line : int
  ; invalid_detail : string
  }

let parse_record payload =
  let invalid line detail = Error { invalid_line = line; invalid_detail = detail } in
  let length = String.length payload in
  let line_end start =
    match String.index_from_opt payload start '\n' with
    | Some stop -> stop
    | None -> length
  in
  let header_end = line_end 0 in
  match
    try header_of_json (Yojson.Safe.from_string (String.sub payload 0 header_end)) with
    | Yojson.Json_error _ -> None
  with
  | None -> invalid 1 "expected the schema_version 2 header"
  | Some header ->
    let rec lines tally ~line ~start =
      if start >= length
      then Ok tally
      else (
        let stop = line_end start in
        if stop - start <> digest_line_length || payload.[start + 1] <> ' '
        then invalid line "expected a tag, a space and a sha256"
        else (
          let sha256 = String.sub payload (start + 2) (digest_line_length - 2) in
          match line_kind_of_tag payload.[start] with
          | None -> invalid line "unknown line tag"
          | Some kind ->
            (match Tool_blob_store.validate_sha256 sha256 with
             | Error invalid_sha256 ->
               invalid line (Tool_blob_store.invalid_sha256_to_string invalid_sha256)
             | Ok () -> lines (add_line kind sha256 tally) ~line:(line + 1) ~start:(stop + 1))))
    in
    let empty =
      { candidate_lines = String_set.empty; deletable_lines = String_set.empty; untouched_lines = 0 }
    in
    (match lines empty ~line:2 ~start:(header_end + 1) with
     | Error _ as error -> error
     | Ok tally ->
       if String_set.cardinal tally.candidate_lines <> header.candidates
          || String_set.cardinal tally.deletable_lines <> header.deletable
          || tally.untouched_lines <> header.untouched_live
       then invalid 1 "header counts do not match the lines"
       else if not (String_set.subset tally.deletable_lines tally.candidate_lines)
       then invalid 1 "a deletable digest is not a candidate"
       else if header.unclassified > 0 && header.deletable > 0
       then invalid 1 "a record with unclassified entries names deletable digests"
       else if (header.current_evicted || header.previous_evicted) && header.deletable > 0
       then invalid 1 "a record with evicted touch marks names deletable digests"
       else
         Ok
           { recorded_scan_started_at = header.scan_started_at
           ; recorded_candidates = tally.candidate_lines
           ; recorded_deletable = tally.deletable_lines
           })
;;

type loaded_record =
  | Record_absent
  | Record_unparsable of invalid_record
  | Record_loaded of record

(* A record that does not parse was not written by a completed scan of this
   format. It is reported and replaced, never compared: deletion needs two
   consecutive recorded scans, so starting over deletes nothing. *)
let load_record ~base_path =
  let path = record_path ~base_path in
  match Fs_compat.load_owned_regular_file ~ownership_root:base_path path with
  | Ok None -> Ok Record_absent
  | Ok (Some payload) ->
    (match parse_record payload with
     | Ok record -> Ok (Record_loaded record)
     | Error invalid -> Ok (Record_unparsable invalid))
  | Error error ->
    Error
      (Record_unreadable { path; detail = Fs_compat.owned_regular_file_read_error_to_string error })
;;

let ensure_maintenance_dir ~base_path ~on_error =
  let dir = maintenance_dir ~base_path in
  let inspect () =
    match Fs_compat.inspect_owned_directory_chain ~ownership_root:base_path dir with
    | Ok observation -> Ok observation
    | Error rejection ->
      Error (on_error (Fs_compat.owned_directory_chain_rejection_to_string rejection))
  in
  match inspect () with
  | Error _ as error -> error
  | Ok (Fs_compat.Owned_directory _) -> Ok ()
  | Ok Fs_compat.Owned_directory_missing ->
    (match Fs_compat.mkdir_p dir with
     | () ->
       (match inspect () with
        | Error _ as error -> error
        | Ok (Fs_compat.Owned_directory _) -> Ok ()
        | Ok Fs_compat.Owned_directory_missing -> Error (on_error "directory was not created"))
     | exception Unix.Unix_error (code, fn, arg) ->
       Error (on_error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)))
     | exception Sys_error detail -> Error (on_error detail))
;;

let write_record
      ~base_path
      ~scan_started_at
      ~candidates
      ~deletable
      ~untouched_live
      ~unclassified
      ~current_evicted
      ~previous_evicted
      ~deleted
      ~deleted_bytes
      ~delete_failures
  =
  let path = record_path ~base_path in
  let on_error detail =
    Record_write_failed { path; detail; deleted; deleted_bytes; delete_failures }
  in
  let open Result.Syntax in
  let* () = ensure_maintenance_dir ~base_path ~on_error in
  let buffer =
    Buffer.create
      ((String_set.cardinal candidates + String_set.cardinal deletable + String_set.cardinal untouched_live + 1)
       * (digest_line_length + 1))
  in
  Buffer.add_string
    buffer
    (Yojson.Safe.to_string
       (header_json
          ~scan_started_at
          ~candidates:(String_set.cardinal candidates)
          ~deletable:(String_set.cardinal deletable)
          ~untouched_live:(String_set.cardinal untouched_live)
          ~unclassified
          ~current_evicted
          ~previous_evicted));
  Buffer.add_char buffer '\n';
  let add kind set =
    String_set.iter
      (fun sha256 ->
         Buffer.add_char buffer (tag_of_line_kind kind);
         Buffer.add_char buffer ' ';
         Buffer.add_string buffer sha256;
         Buffer.add_char buffer '\n')
      set
  in
  add Candidate candidates;
  add Deletable deletable;
  add Untouched_live untouched_live;
  match Fs_compat.save_file_atomic_strict path (Buffer.contents buffer) with
  | Ok () -> Ok ()
  | Error detail -> Error (on_error detail)
;;

(* The marker is replaced, never rewritten in place, so its mtime is the
   instant this scan opened as the filesystem records it. *)
let open_scan ~base_path =
  let path = marker_path ~base_path in
  let on_error detail = Marker_failed { path; detail } in
  let open Result.Syntax in
  let* () = ensure_maintenance_dir ~base_path ~on_error in
  let* () =
    match Fs_compat.save_file_atomic_strict path "" with
    | Ok () -> Ok ()
    | Error detail -> Error (on_error detail)
  in
  match marker_mtime ~base_path with
  | Error _ as error -> error
  | Ok None -> Error (on_error "marker disappeared after it was written")
  | Ok (Some opened_at) -> Ok opened_at
;;

(* {1 Scan} *)

type deletable_tally =
  { deletable_set : String_set.t
  ; bytes : int
  ; unstatable_count : int
  }

(* Candidates of both scans, minus this process's marks,
   minus files written since the previous scan opened, and (when [min_age_seconds > 0.0])
   minus files newer than [scan_started_at -. min_age_seconds]. *)
let deletable_now ~store ~touches ~(previous : record) ~scan_started_at ~min_age_seconds ~candidates =
  let age_cutoff = scan_started_at -. min_age_seconds in
  String_set.fold
    (fun sha256 tally ->
       match Tool_blob_store.touch_of touches ~sha256 with
       | Some _ -> tally
       | None ->
         (match Tool_blob_store.blob_status store ~sha256 with
          | Tool_blob_store.Present { bytes; modified_at }
            when modified_at < previous.recorded_scan_started_at
                 && (min_age_seconds <= 0.0 || modified_at <= age_cutoff) ->
            { tally with deletable_set = String_set.add sha256 tally.deletable_set
            ; bytes = tally.bytes + bytes }
          | Tool_blob_store.Present _ | Tool_blob_store.Absent -> tally
          | Tool_blob_store.Not_regular _ | Tool_blob_store.Stat_failed _ ->
            { tally with unstatable_count = tally.unstatable_count + 1 }))
    (String_set.inter previous.recorded_candidates candidates)
    { deletable_set = String_set.empty; bytes = 0; unstatable_count = 0 }
;;

type now_live_class =
  | Rewritten
  | Read_only
  | Untouched

(* What would have happened to a blob that a deleting sweep removed at the
   end of the previous scan, now that a durable consumer references it. *)
let classify_now_live ~store ~touches ~(previous : record) sha256 =
  let written_since =
    match Tool_blob_store.blob_status store ~sha256 with
    | Tool_blob_store.Present { modified_at; bytes = _ } ->
      modified_at >= previous.recorded_scan_started_at
    | Tool_blob_store.Absent | Tool_blob_store.Not_regular _ | Tool_blob_store.Stat_failed _ ->
      false
  in
  match Tool_blob_store.touch_of touches ~sha256 with
  | None -> if written_since then Rewritten else Untouched
  | Some (mark : Tool_blob_store.touch) ->
    if mark.put || written_since then Rewritten
    else if mark.read then Read_only
    else Untouched
;;

let compare_previous ~store ~touches ~(previous : record) ~live =
  let now_live, untouched =
    String_set.fold
      (fun sha256 ((counts : previous_now_live), untouched) ->
         match classify_now_live ~store ~touches ~previous sha256 with
         | Rewritten -> { counts with rewritten = counts.rewritten + 1 }, untouched
         | Read_only -> { counts with read_only = counts.read_only + 1 }, untouched
         | Untouched ->
           { counts with untouched = counts.untouched + 1 }, String_set.add sha256 untouched)
      (String_set.inter previous.recorded_deletable live)
      ({ rewritten = 0; read_only = 0; untouched = 0 }, String_set.empty)
  in
  let previous_deletable_read =
    String_set.fold
      (fun sha256 count ->
         match Tool_blob_store.touch_of touches ~sha256 with
         | Some (mark : Tool_blob_store.touch) -> if mark.read then count + 1 else count
         | None -> count)
      previous.recorded_deletable
      0
  in
  ( { previous_deletable = String_set.cardinal previous.recorded_deletable
    ; previous_deletable_read
    ; now_live
    }
  , untouched )
;;

let has_unpinnable_warning warnings =
  List.exists
    (function
      | Tool_blob_maintenance.Unpinnable_malformed_blob_ref _ -> true
      | Tool_blob_maintenance.Pinned_legacy_blob_ref _ -> false)
    warnings
;;

type reclaim_tally =
  { removed : String_set.t
  ; deleted_count : int
  ; deleted_bytes : int
  ; delete_failures : int
  }

let reclaim_confirmed_deletable
      ~store
      ~(previous : record)
      ~scan_started_at
      ~min_age_seconds
      deletable_set
  =
  let age_cutoff = scan_started_at -. min_age_seconds in
  String_set.fold
    (fun sha256 tally ->
       (* Re-check the touch ledger (including overflow flags) and file mtime
          immediately before unlinking so a concurrent put/fetch or touch-ledger
          eviction arriving during the scan never deletes a live blob. *)
       let fresh_touches = Tool_blob_store.observe_touches () in
       let fresh_counts = Tool_blob_store.touch_counts fresh_touches in
       if fresh_counts.current_evicted || fresh_counts.previous_evicted
       then tally
       else
       match Tool_blob_store.touch_of fresh_touches ~sha256 with
       | Some _ -> tally
       | None ->
         (match Tool_blob_store.blob_status store ~sha256 with
          | Tool_blob_store.Present { bytes; modified_at }
            when modified_at < previous.recorded_scan_started_at
                 && (min_age_seconds <= 0.0 || modified_at <= age_cutoff) ->
            (match Tool_blob_store.delete store ~sha256 with
             | Ok true ->
               { tally with
                 removed = String_set.add sha256 tally.removed
               ; deleted_count = tally.deleted_count + 1
               ; deleted_bytes = tally.deleted_bytes + bytes
               }
             | Ok false ->
               { tally with removed = String_set.add sha256 tally.removed }
             | Error _ ->
               { tally with delete_failures = tally.delete_failures + 1 })
          | Tool_blob_store.Present _
          | Tool_blob_store.Absent
          | Tool_blob_store.Not_regular _
          | Tool_blob_store.Stat_failed _ -> tally))
    deletable_set
    { removed = String_set.empty; deleted_count = 0; deleted_bytes = 0; delete_failures = 0 }
;;

let scan_internal ~reclaim_mode ~min_age_seconds ~base_path ~scope =
  let open Result.Syntax in
  let store = Tool_blob_store.create ~base_path in
  (* The marker comes first: a scan that cannot read its previous record still
     counts as opened, so {!schedule} waits a day before the next attempt. *)
  let* scan_started_at = open_scan ~base_path in
  let* previous = load_record ~base_path in
  (* NDT-OK: scan duration is an operator measurement, not a decision. *)
  let clock_started = Unix.gettimeofday () in
  let* live_references, malformed_warnings =
    Result.map_error
      (fun error -> Scan_failed error)
      (Tool_blob_maintenance.live_references_resilient ~base_path ~scope)
  in
  (* An entry no rule classifies is a place the scan does not read. The scan
     still records, but names nothing deletable. *)
  let* unclassified =
    Result.map_error
      (fun error -> Scan_failed error)
      (Tool_blob_maintenance.unclassified_entries ~base_path scope)
  in
  let unclassified = List.map Tool_blob_maintenance.unclassified_entry_to_string unclassified in
  let live =
    Tool_blob_maintenance.fold_live_sha256
      live_references
      ~init:String_set.empty
      ~f:(fun live sha256 -> String_set.add sha256 live)
  in
  let* blobs =
    Result.map_error (fun error -> Listing_failed error) (Tool_blob_store.list_all_result store)
  in
  let blob_count, candidates =
    List.fold_left
      (fun (count, candidates) sha256 ->
         ( count + 1
         , if String_set.mem sha256 live then candidates else String_set.add sha256 candidates ))
      (0, String_set.empty)
      blobs
  in
  let touches = Tool_blob_store.observe_touches () in
  let touch_counts = Tool_blob_store.touch_counts touches in
  let nothing_deletable = { deletable_set = String_set.empty; bytes = 0; unstatable_count = 0 } in
  let deletion_allowed =
    unclassified = []
    && not (has_unpinnable_warning malformed_warnings)
    && not touch_counts.current_evicted
    && not touch_counts.previous_evicted
  in
  let deletable, comparison, untouched_live, loaded_previous =
    match previous with
    | Record_absent -> nothing_deletable, No_previous_record, String_set.empty, None
    | Record_unparsable { invalid_line; invalid_detail } ->
      ( nothing_deletable
      , Previous_record_invalid { line = invalid_line; detail = invalid_detail }
      , String_set.empty
      , None )
    | Record_loaded previous ->
      let comparison, untouched = compare_previous ~store ~touches ~previous ~live in
      ( (if deletion_allowed
         then
           deletable_now
             ~store
             ~touches
             ~previous
             ~scan_started_at
             ~min_age_seconds
             ~candidates
         else nothing_deletable)
      , Compared_with_previous comparison
      , untouched
      , Some previous )
  in
  let reclaimed =
    if reclaim_mode && deletion_allowed
    then
      match loaded_previous with
      | Some previous ->
        reclaim_confirmed_deletable
          ~store
          ~previous
          ~scan_started_at
          ~min_age_seconds
          deletable.deletable_set
      | None ->
        { removed = String_set.empty; deleted_count = 0; deleted_bytes = 0; delete_failures = 0 }
    else
      { removed = String_set.empty; deleted_count = 0; deleted_bytes = 0; delete_failures = 0 }
  in
  let recorded_candidates = String_set.diff candidates reclaimed.removed in
  let recorded_deletable = String_set.diff deletable.deletable_set reclaimed.removed in
  let* () =
    write_record
      ~base_path
      ~scan_started_at
      ~candidates:recorded_candidates
      ~deletable:recorded_deletable
      ~untouched_live
      ~unclassified
      ~current_evicted:touch_counts.current_evicted
      ~previous_evicted:touch_counts.previous_evicted
      ~deleted:reclaimed.deleted_count
      ~deleted_bytes:reclaimed.deleted_bytes
      ~delete_failures:reclaimed.delete_failures
  in
  Tool_blob_store.rotate_touches ();
  Ok
    { scan_started_at
    ; scan_seconds = Unix.gettimeofday () -. clock_started
    ; live_digests = String_set.cardinal live
    ; blobs = blob_count
    ; candidates = String_set.cardinal recorded_candidates
    ; deletable = String_set.cardinal deletable.deletable_set
    ; deletable_bytes = deletable.bytes
    ; deleted = reclaimed.deleted_count
    ; deleted_bytes = reclaimed.deleted_bytes
    ; delete_failures = reclaimed.delete_failures
    ; unstatable = deletable.unstatable_count
    ; unclassified
    ; malformed_warnings
    ; previous = comparison
    ; touches = touch_counts
    }
;;

let observe ~base_path ~scope =
  scan_internal ~reclaim_mode:false ~min_age_seconds:0.0 ~base_path ~scope
;;

let reclaim ?(min_age_seconds = Masc_time_constants.day) ~base_path ~scope () =
  scan_internal
    ~reclaim_mode:true
    ~min_age_seconds:(Float.max 0.0 min_age_seconds)
    ~base_path
    ~scope
;;
