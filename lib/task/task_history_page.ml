open Result.Syntax

include Task_history_types
include Task_history_inventory
include Task_history_reader
include Task_history_row
include Task_history_scan
include Task_history_segment

let cursor_json cursor =
  let p=cursor.position in
  `Assoc ["schema",`String "masc.task-history.cursor/v2";"task_id",`String cursor.task;
    "workspace",`String cursor.workspace;"ceilings",`List (List.map (fun (c:ceiling) ->
      `Assoc ["file",`String c.file;"size",`Int c.size]) cursor.ceilings);
    "inventory",`String cursor.inventory;"file",`String p.file;"device",`Int p.device;
    "inode",`Int p.inode;"before",`Int p.before;"anchor",`String p.anchor]
let cursor_to_string cursor = Yojson.Safe.to_string (cursor_json cursor)
  |> Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
let cursor_of_string encoded =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet encoded with
  | Error _ -> Error Invalid_cursor
  | Ok bytes ->
    (match Yojson.Safe.from_string bytes with
     | `Assoc fields when List.length fields=10 ->
       let text name = match List.assoc_opt name fields with
         | Some (`String value) when value<>"" && value=String.trim value -> Some value
         | Some _ | None -> None in
       let integer name = match List.assoc_opt name fields with
         | Some (`Int value) when value>=0 -> Some value | Some _ | None -> None in
       let ceilings=match List.assoc_opt "ceilings" fields with
         | Some (`List rows) ->
           List.fold_left (fun result row -> let* acc=result in match row with
             | `Assoc ["file",`String file;"size",`Int size] when size>=0 && Option.is_some (dated_parts file) ->
               if List.exists (fun (c:ceiling) -> match dated_parts c.file,dated_parts file with
                 | Some (left,_,_),Some (right,_,_) -> left=right | _ -> false) acc
               then Error Invalid_cursor else Ok (acc @ [{file;size}])
             | _ -> Error Invalid_cursor) (Ok []) rows
         | _ -> Error Invalid_cursor in
       (match ceilings with
        | Error _ -> Error Invalid_cursor
        | Ok ceilings ->
          (match text "schema",text "task_id",text "workspace",text "inventory",
                 text "file",integer "device",integer "inode",integer "before",text "anchor" with
           | Some "masc.task-history.cursor/v2",Some task,Some workspace,Some inventory,
             Some file,Some device,Some inode,Some before,Some anchor
             when ceilings<>[] && Option.is_some (dated_parts file) ->
             let cursor={task;workspace;ceilings;inventory;position={file;device;inode;before;anchor}} in
             if cursor_to_string cursor=encoded then Ok cursor else Error Invalid_cursor
           | _ -> Error Invalid_cursor))
     | _ -> Error Invalid_cursor
     | exception Yojson.Json_error _ -> Error Invalid_cursor)

let event_envelope ~file ~offset json =
  `Assoc [
    "source", `String (source_name file.source);
    "file", `String file.relative;
    "offset", `Int offset;
    "event", json;
  ]

type range_scan_outcome =
  | Reached_stop of {
      stopped_from : int;
      row_count : int;
      first_row_offset : int;
      collected : Yojson.Safe.t list;
      count : int;
      by_task : int list String_map.t;
      conflicting : int list String_map.t;
    }
  | Filled_page of {
      stopped_from : int;
      row_count : int;
      first_row_offset : int;
      anchor_line : string;
      collected : Yojson.Safe.t list;
      by_task : int list String_map.t;
      conflicting : int list String_map.t;
    }

let scan_range_raw ~task_id ~file ~reader ~start_before ~stop_at ~max_events ~collected ~count =
  let key_buf = Array.make (max_fast_depth * key_stride) 0 in
  let state = Array.make 13 0 in
  let table = create_task_table () in
  let slice = { row_offset = 0; row_buf = ""; row_pos = 0; row_len = 0 } in
  let rec loop before row_count first_row_offset collected count rev_conflicting =
    if before <= stop_at then
      Ok (Reached_stop {
        stopped_from = before;
        row_count;
        first_row_offset;
        collected;
        count;
        by_task = task_table_to_map table;
        conflicting = String_map.map List.rev rev_conflicting;
      })
    else
      let* has_row = previous_slice reader slice before in
      if not has_row then
        Ok (Reached_stop {
          stopped_from = 0;
          row_count;
          first_row_offset;
          collected;
          count;
          by_task = task_table_to_map table;
          conflicting = String_map.map List.rev rev_conflicting;
        })
      else
        let offset = slice.row_offset in
        if is_blank_slice slice.row_buf ~pos:slice.row_pos ~len:slice.row_len then
          loop offset row_count first_row_offset collected count rev_conflicting
        else
          let row_count = row_count + 1 in
          let first_row_offset = offset in
          match scan_row_slice_fast ~source:file.source slice.row_buf ~pos:slice.row_pos ~len:slice.row_len key_buf state with
          | 0 (* Fast_unrelated *) ->
            loop offset row_count first_row_offset collected count rev_conflicting
          | 1 (* Fast_task *) ->
            let id_off = Array.unsafe_get state 1 in
            let id_len = Array.unsafe_get state 2 in
            if not (slice_eq_lit slice.row_buf id_off id_len task_id) then (
              add_slice_to_table table slice.row_buf id_off id_len offset;
              loop offset row_count first_row_offset collected count rev_conflicting)
            else
              let line = slice_to_string slice in
              (match classify_row ~source:file.source line with
               | Row_task { task_id = row_tid; json } when String.equal row_tid task_id ->
                 add_string_to_table table row_tid offset;
                 let event = event_envelope ~file ~offset json in
                 let collected = event :: collected in
                 let count = count + 1 in
                 if count < max_events then
                   loop offset row_count first_row_offset collected count rev_conflicting
                 else
                   Ok (Filled_page {
                     stopped_from = offset;
                     row_count;
                     first_row_offset;
                     anchor_line = line;
                     collected;
                     by_task = task_table_to_map table;
                     conflicting = String_map.map List.rev rev_conflicting;
                   })
               | Row_invalid | Row_unrelated | Row_conflicting _ | Row_task _ ->
                 Error (Invalid_event { file = file.relative; offset }))
          | _ (* Fast_fallback *) ->
            let line = slice_to_string slice in
            match classify_row ~source:file.source line with
            | Row_invalid ->
              Error (Invalid_event { file = file.relative; offset })
            | Row_unrelated ->
              loop offset row_count first_row_offset collected count rev_conflicting
            | Row_conflicting { string_ids } ->
              let rev_conflicting =
                List.fold_left (fun acc tid -> add_offset_to_map tid offset acc) rev_conflicting string_ids
              in
              if List.exists (String.equal task_id) string_ids then
                Error (Invalid_event { file = file.relative; offset })
              else
                loop offset row_count first_row_offset collected count rev_conflicting
            | Row_task { task_id = row_tid; json } ->
              add_string_to_table table row_tid offset;
              if not (String.equal row_tid task_id) then
                loop offset row_count first_row_offset collected count rev_conflicting
              else
                let event = event_envelope ~file ~offset json in
                let collected = event :: collected in
                let count = count + 1 in
                if count < max_events then
                  loop offset row_count first_row_offset collected count rev_conflicting
                else
                  Ok (Filled_page {
                    stopped_from = offset;
                    row_count;
                    first_row_offset;
                    anchor_line = line;
                    collected;
                    by_task = task_table_to_map table;
                    conflicting = String_map.map List.rev rev_conflicting;
                  })
  in
  loop start_before 0 (-1) collected count String_map.empty

let rec drop_ge limit = function
  | off :: rest when off >= limit -> drop_ge limit rest
  | list -> list

let rec take_up_to n acc = function
  | [] -> List.rev acc, None
  | x :: _ when n <= 1 -> List.rev (x :: acc), Some x
  | x :: rest -> take_up_to (n - 1) (x :: acc) rest

type file_step =
  | Step_done of Yojson.Safe.t list * cursor option
  | Step_next_file of Yojson.Safe.t list * int

let read ~config ~task_id ~max_events ?cursor () =
  if task_id="" || task_id<>String.trim task_id || max_events<=0 then Error Invalid_request
  else
    Fs_compat.with_owned_inventory_root (Workspace_core.masc_dir config) (fun held ->
      let root=Fs_compat.owned_inventory_root_path held in
      let run () =
        let* workspace=match Fs_compat.inspect_owned_directory_chain ~ownership_root:root root with
          | Ok (Fs_compat.Owned_directory stat) ->
            Ok (hash (Yojson.Safe.to_string (`List [`String root;`Int stat.st_dev;`Int stat.st_ino])))
          | Ok Owned_directory_missing | Error _ -> Error Source_changed in
        let* all=inventory ~root ~held in
        let ceilings=match cursor with Some cursor -> cursor.ceilings | None -> capture all.files in
        let files=prefix ~ceilings all.files in
        let fingerprint=inventory_hash ~ceilings all in
        let* ()=match cursor with
          | None -> Ok ()
          | Some cursor when cursor.task=task_id && cursor.workspace=workspace
              && cursor.inventory=fingerprint -> Ok ()
          | Some _ -> Error Source_changed in
        let* files=match cursor with
          | None -> Ok files
          | Some cursor ->
            let rec find = function
              | [] -> Error Source_changed
              | file::rest as files -> if file.relative=cursor.position.file then Ok files else find rest in
            find files in
        let make_next_cursor (file : file) rest offset anchor_line =
          if offset=0 && rest=[] then None
          else
            Some {
              task=task_id;
              workspace;
              ceilings;
              inventory=fingerprint;
              position={
                file=file.relative;
                device=file.snapshot.device;
                inode=file.snapshot.inode;
                before=offset;
                anchor=hash anchor_line;
              };
            }
        in
        let scan_one_file ~first ~file ~rest initial_collected initial_count =
          let ceiling_opt = List.find_opt (fun (c : ceiling) -> c.file = file.relative) ceilings in
          let is_ceiling = Option.is_some ceiling_opt in
          (* Scans, block digests, and index construction run unlocked so a slow
             cold scan never blocks another worker domain that would hash to the
             same stripe. [store_cached_segment] serializes only publication and
             enforces monotonic range/snapshot replacement; [invalidate_cached_segment_if_same]
             removes only the exact stale entry observed by this fiber. *)
          with_reader ~root file (fun reader ->
            let* initial_before =
              match first, cursor with
              | true, Some cursor ->
                let* () = anchor_matches reader cursor.position in
                Ok cursor.position.before
              | false, _ | true, None ->
                Ok (match ceiling_opt with
                  | Some c -> c.size
                  | None -> file.snapshot.file_size)
            in
            if initial_before = 0 then Ok (Step_next_file (initial_collected, initial_count))
            else
              let raw_cached_opt = find_cached_segment ~root ~relative:file.relative in
              let scan_cold_from_initial ?stale () =
                Option.iter
                  (invalidate_cached_segment_if_same ~root ~relative:file.relative)
                  raw_cached_opt;
                Option.iter
                  (invalidate_cached_segment_if_same ~root ~relative:file.relative)
                  stale;
                reset_reader_block_memo reader;
                let* outcome =
                  scan_range_raw ~task_id ~file ~reader ~start_before:initial_before
                    ~stop_at:0 ~max_events ~collected:initial_collected ~count:initial_count
                in
                let cache_cold ~stopped_from ~row_count ~first_row_offset ~by_task ~conflicting =
                  if stopped_from >= initial_before then Ok ()
                  else
                    let* seg =
                      make_cached_segment reader ~scanned_from:stopped_from
                        ~scanned_to:initial_before ~row_count ~first_row_offset ~by_task ~conflicting
                    in
                    Ok (store_cached_segment ~root ~relative:file.relative seg)
                in
                match outcome with
                | Filled_page { stopped_from; row_count; first_row_offset; anchor_line; collected; by_task; conflicting } ->
                  let* () = cache_cold ~stopped_from ~row_count ~first_row_offset ~by_task ~conflicting in
                  Ok (Step_done (List.rev collected, make_next_cursor file rest stopped_from anchor_line))
                | Reached_stop { stopped_from; row_count; first_row_offset; collected; count; by_task; conflicting } ->
                  let* () = cache_cold ~stopped_from ~row_count ~first_row_offset ~by_task ~conflicting in
                  Ok (Step_next_file (collected, count))
              in
              let* cached_opt =
                match raw_cached_opt with
                | None -> Ok None
                | Some cached ->
                  let* ok = verify_cached_segment ~is_ceiling reader cached in
                  if ok then Ok (Some cached)
                  else (
                    invalidate_cached_segment_if_same ~root ~relative:file.relative cached;
                    Ok None)
              in
              (* Step 1: if initial_before > cached.scanned_to, scan the appended upper delta [cached.scanned_to, initial_before) *)
              let* step1 =
                match cached_opt with
                | Some cached when initial_before > cached.scanned_to ->
                  let* outcome =
                    scan_range_raw ~task_id ~file ~reader ~start_before:initial_before
                      ~stop_at:cached.scanned_to ~max_events ~collected:initial_collected ~count:initial_count
                  in
                  let merge_first_offset upper_first lower_first =
                    if lower_first >= 0 then lower_first else upper_first
                  in
                  (match outcome with
                   | Filled_page { stopped_from; row_count; first_row_offset; anchor_line; collected; by_task; conflicting } ->
                     if stopped_from < cached.scanned_to then
                       Ok `Fallback_cold
                     else
                       let* () =
                         if stopped_from = cached.scanned_to then
                           let by_task' = merge_desc_maps by_task cached.by_task in
                           let conflicting' = merge_desc_maps conflicting cached.conflicting in
                           let* seg =
                             make_cached_segment reader ~scanned_from:cached.scanned_from
                               ~scanned_to:initial_before
                               ~row_count:(row_count + cached.row_count)
                               ~first_row_offset:(merge_first_offset first_row_offset cached.first_row_offset)
                               ~by_task:by_task' ~conflicting:conflicting'
                           in
                           Ok (store_cached_segment ~root ~relative:file.relative seg)
                         else Ok ()
                       in
                       Ok (`Done (Step_done (List.rev collected, make_next_cursor file rest stopped_from anchor_line)))
                   | Reached_stop { stopped_from; row_count; first_row_offset; collected; count; by_task; conflicting } ->
                     if stopped_from <> cached.scanned_to then
                       Ok `Fallback_cold
                     else
                       let by_task' = merge_desc_maps by_task cached.by_task in
                       let conflicting' = merge_desc_maps conflicting cached.conflicting in
                       let* seg =
                         make_cached_segment reader ~scanned_from:cached.scanned_from
                           ~scanned_to:initial_before
                           ~row_count:(row_count + cached.row_count)
                           ~first_row_offset:(merge_first_offset first_row_offset cached.first_row_offset)
                           ~by_task:by_task' ~conflicting:conflicting'
                       in
                       store_cached_segment ~root ~relative:file.relative seg;
                       Ok (`Continue (cached.scanned_to, collected, count, Some seg)))
                | _ -> Ok (`Continue (initial_before, initial_collected, initial_count, cached_opt))
              in
              match step1 with
              | `Fallback_cold -> scan_cold_from_initial ()
              | `Done done_step -> Ok done_step
              | `Continue (before, collected, count, cached_opt) ->
                (* Step 2: if cached.scanned_from < before <= cached.scanned_to, use cached segment *)
                let* step2 =
                  match cached_opt with
                  | Some cached when cached.scanned_from < before && before <= cached.scanned_to ->
                    let* () =
                      if before = cached.scanned_to then Ok ()
                      else
                        let* ending = byte reader (before - 1) in
                        if ending = '\n' then Ok ()
                        else Error (Invalid_event { file = file.relative; offset = before - 1 })
                    in
                    let task_offsets =
                      match String_map.find_opt task_id cached.by_task with
                      | None -> []
                      | Some list -> drop_ge before list
                    in
                    let conflict_offsets =
                      match String_map.find_opt task_id cached.conflicting with
                      | None -> []
                      | Some list -> drop_ge before list
                    in
                    let needed = max_events - count in
                    let taken, stop_offset_opt = take_up_to needed [] task_offsets in
                    let lower_bound =
                      match stop_offset_opt with
                      | Some stop_off -> stop_off
                      | None -> cached.scanned_from - 1
                    in
                    (match conflict_offsets with
                     | c_off :: _ when c_off > lower_bound ->
                       Ok `Fallback_cold
                     | _ ->
                       let rec materialize collected count last_line = function
                         | [] -> Ok (`Materialized (collected, count, last_line))
                         | off :: more ->
                           let* start_ok =
                             if off = 0 then Ok true
                             else
                               let* prev = byte reader (off - 1) in
                               Ok (prev = '\n')
                           in
                           if not start_ok then Ok `Invalidated
                           else
                             let* line_opt = read_line_at_bounded reader ~limit:before off in
                             match line_opt with
                             | None -> Ok `Invalidated
                             | Some line ->
                               let line_end = off + String.length line in
                               let* end_ok =
                                 if line_end >= before then Ok false
                                 else
                                   let* term = byte reader line_end in
                                   Ok (term = '\n')
                               in
                               if not end_ok then Ok `Invalidated
                               else
                                 match classify_row ~source:file.source line with
                                 | Row_task { task_id = row_tid; json } when String.equal row_tid task_id ->
                                   let event = event_envelope ~file ~offset:off json in
                                   materialize (event :: collected) (count + 1) line more
                                 | Row_task _ | Row_unrelated | Row_conflicting _ | Row_invalid ->
                                   Ok `Invalidated
                       in
                       let* mat_result = materialize collected count "" taken in
                       match mat_result with
                       | `Invalidated -> Ok `Fallback_cold
                       | `Materialized (collected, count, last_line) ->
                         (match stop_offset_opt with
                          | Some stop_off ->
                            Ok (`Done (Step_done (List.rev collected, make_next_cursor file rest stop_off last_line)))
                          | None ->
                            if cached.scanned_from = 0 then
                              Ok (`Continue (0, collected, count, Some cached))
                            else
                              let* prev = byte reader (cached.scanned_from - 1) in
                              if prev = '\n' then
                                Ok (`Continue (cached.scanned_from, collected, count, Some cached))
                              else
                                Ok `Fallback_cold))
                  | _ -> Ok (`Continue (before, collected, count, cached_opt))
                in
                match step2 with
                | `Fallback_cold -> scan_cold_from_initial ?stale:cached_opt ()
                | `Done done_step -> Ok done_step
                | `Continue (before, collected, count, cached_opt) ->
                  (* Step 3: scan remaining prefix [0, before) *)
                  if before = 0 then Ok (Step_next_file (collected, count))
                  else
                    let* outcome =
                      scan_range_raw ~task_id ~file ~reader ~start_before:before
                        ~stop_at:0 ~max_events ~collected ~count
                    in
                    let cache_lower ~stopped_from ~row_count ~first_row_offset ~by_task ~conflicting =
                      if stopped_from >= before then Ok ()
                      else
                        match cached_opt with
                        | Some cached when before = cached.scanned_from ->
                          let by_task' = merge_desc_maps cached.by_task by_task in
                          let conflicting' = merge_desc_maps cached.conflicting conflicting in
                          let merged_first =
                            if first_row_offset >= 0 then first_row_offset else cached.first_row_offset
                          in
                          let* seg =
                            make_cached_segment reader ~scanned_from:stopped_from
                              ~scanned_to:cached.scanned_to
                              ~row_count:(cached.row_count + row_count)
                              ~first_row_offset:merged_first
                              ~by_task:by_task' ~conflicting:conflicting'
                          in
                          Ok (store_cached_segment ~root ~relative:file.relative seg)
                        | None ->
                          let* seg =
                            make_cached_segment reader ~scanned_from:stopped_from
                              ~scanned_to:before ~row_count ~first_row_offset ~by_task ~conflicting
                          in
                          Ok (store_cached_segment ~root ~relative:file.relative seg)
                        | Some _ -> Ok ()
                    in
                    (match outcome with
                     | Filled_page { stopped_from; row_count; first_row_offset; anchor_line; collected; by_task; conflicting } ->
                       let* () = cache_lower ~stopped_from ~row_count ~first_row_offset ~by_task ~conflicting in
                       Ok (Step_done (List.rev collected, make_next_cursor file rest stopped_from anchor_line))
                     | Reached_stop { stopped_from; row_count; first_row_offset; collected; count; by_task; conflicting } ->
                       let* () = cache_lower ~stopped_from ~row_count ~first_row_offset ~by_task ~conflicting in
                       Ok (Step_next_file (collected, count))))
        in
        let rec scan_files first collected count = function
          | [] -> Ok (List.rev collected, None)
          | file :: rest ->
            let* step = scan_one_file ~first ~file ~rest collected count in
            match step with
            | Step_done (events, next_cursor) -> Ok (events, next_cursor)
            | Step_next_file (collected, count) -> scan_files false collected count rest
        in
        let* events,next_cursor=scan_files true [] 0 files in
        let* after=inventory ~root ~held in
        if inventory_hash ~ceilings after<>fingerprint then Error Source_changed
        else Ok {task_id;cursor;sources=all.observations;events;next_cursor} in
      Ok (run ()))
    |> function Ok result -> result | Error _ -> Error Source_unavailable

let to_json page =
  let token = function None -> `Null | Some cursor -> `String (cursor_to_string cursor) in
  let sources=List.map (fun (source,availability) -> `Assoc ["source",`String (source_name source);
    "state",`String (match availability with Observed -> "observed" | Not_created -> "not-created")]) page.sources in
  `Assoc ["schema",`String "masc.task-history.page/v2";"task_id",`String page.task_id;
    "cursor",token page.cursor;"sources",`List sources;"events",`List page.events;"next_cursor",token page.next_cursor]
