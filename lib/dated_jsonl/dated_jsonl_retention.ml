(* Calendar/file layout is the writer's existing pure contract. Effects use
   only held directory capabilities, including empty-month retirement. *)
let prune ~cutoff_month ~cutoff_day directory =
  let module Directory = Fs_compat.Retention_directory in
  Directory.names directory
  |> List.fold_left (fun deleted month_name ->
    match Dated_jsonl_layout.year_and_month_of_directory_name month_name with
    | None -> deleted
    | Some (year, month) ->
      let comparison = String.compare month_name cutoff_month in
      if comparison > 0 then deleted
      else
        let removed = Directory.with_child directory month_name (fun month_dir ->
          Directory.names month_dir
          |> List.fold_left (fun count name ->
            if Dated_jsonl_layout.day_file_name_is_valid ~year ~month name
               && (comparison < 0
                   || String.compare
                        (Dated_jsonl_layout.day_number_of_day_file_name name) cutoff_day < 0)
               && Directory.remove_regular_file month_dir name
            then count + 1 else count) 0) in
        if comparison < 0 then Directory.remove_empty_child directory month_name;
        deleted + (match removed with None -> 0 | Some count -> count)) 0
