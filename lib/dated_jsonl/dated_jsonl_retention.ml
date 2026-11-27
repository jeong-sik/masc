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
          let entries = Directory.names month_dir in
          let eligible =
            List.filter (fun name ->
              Dated_jsonl_layout.day_file_name_is_valid ~year ~month name
              && (comparison < 0
                  || String.compare
                       (Dated_jsonl_layout.day_number_of_day_file_name name) cutoff_day < 0))
              entries
          in
          let count =
            match eligible with
            | [] -> 0
            | _ :: _ -> Directory.remove_regular_files month_dir eligible
          in
          let may_be_empty = entries = [] || count > 0 in
          count, may_be_empty) in
        match removed with
        | None -> deleted
        | Some (count, may_be_empty) ->
          if may_be_empty then Directory.remove_empty_child directory month_name;
          deleted + count) 0
