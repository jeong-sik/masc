(** Offline mention backfill — see the interface for the contract. *)

type file_report = {
  path : string;
  total_lines : int;
  rewritten : int;
}

let backfill_line (line : string) : string option =
  match Yojson.Safe.from_string line with
  | exception Yojson.Json_error _ -> None
  | `Assoc fields ->
      let is_user_row =
        match List.assoc_opt "role" fields with
        | Some (`String "user") -> true
        | _ -> false
      in
      if (not is_user_row) || List.mem_assoc "mentions" fields then None
      else (
        let content =
          match List.assoc_opt "content" fields with
          | Some (`String value) -> value
          | _ -> ""
        in
        match Keeper_lane_mentions.mention_ids_of_content content with
        | [] -> None
        | ids ->
            let mentions_field =
              ( "mentions",
                `List
                  (List.map
                     (fun id ->
                       `String (Keeper_identity.Keeper_id.to_string id))
                     ids) )
            in
            Some (Yojson.Safe.to_string (`Assoc (fields @ [ mentions_field ]))))
  | _ -> None

let read_lines path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () ->
      try close_in ic with
      | Sys_error _ -> ())
    (fun () ->
      let rec loop acc =
        match input_line ic with
        | line -> loop (line :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])

let backfill_file ~dry_run path =
  let lines = read_lines path in
  let rewritten = ref 0 in
  let out_lines =
    List.map
      (fun line ->
        match backfill_line line with
        | Some replacement ->
            incr rewritten;
            replacement
        | None -> line)
      lines
  in
  if (not dry_run) && !rewritten > 0 then (
    let tmp = path ^ ".backfill-tmp" in
    let oc = open_out_bin tmp in
    Fun.protect
      ~finally:(fun () ->
        try close_out oc with
        | Sys_error _ -> ())
      (fun () ->
        List.iter
          (fun line ->
            output_string oc line;
            output_char oc '\n')
          out_lines);
    Sys.rename tmp path);
  { path; total_lines = List.length lines; rewritten = !rewritten }

let backfill_base_path ~dry_run base_path =
  let dir =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path)
      "keeper_chat"
  in
  if not (Sys.file_exists dir && Sys.is_directory dir) then []
  else
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
    |> List.sort String.compare
    |> List.map (fun name ->
           backfill_file ~dry_run (Filename.concat dir name))
