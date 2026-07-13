type t = {
  base_dir : string;
  mutable latest_hash : string option;
}

exception Corrupt_jsonl of {
  path : string;
  line_number : int;
  detail : string;
}

let parse_jsonl_line line =
  try Yojson.Safe.from_string line |> Envelope.of_json with
  | Yojson.Json_error msg -> Error msg

let read_jsonl_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let entries = ref [] in
      let line_number = ref 0 in
      (try
         while true do
           let line = input_line ic in
           incr line_number;
           if String.length line > 0 then
             match parse_jsonl_line line with
             | Ok env -> entries := env :: !entries
             | Error detail ->
               raise (Corrupt_jsonl { path; line_number = !line_number; detail })
         done
       with End_of_file -> ());
      List.rev !entries)

let load_latest_hash ~base_dir =
  if not (Sys.file_exists base_dir) then None
  else if not (Sys.is_directory base_dir) then None
  else
    let months =
      Sys.readdir base_dir
      |> Array.to_list
      |> List.filter (fun s -> String.length s = 7 && s.[4] = '-')
      |> List.sort (fun a b -> String.compare b a)
    in
    let rec find_in_months = function
      | [] -> None
      | m :: rest ->
        let m_dir = Filename.concat base_dir m in
        if not (Sys.is_directory m_dir) then find_in_months rest
        else
          let days =
            Sys.readdir m_dir
            |> Array.to_list
            |> List.filter (fun s -> Filename.check_suffix s ".jsonl")
            |> List.sort (fun a b -> String.compare b a)
          in
          (match days with
           | [] -> find_in_months rest
           | d :: _ ->
             let path = Filename.concat m_dir d in
             let entries = read_jsonl_file path in
             (match List.rev entries with
              | last :: _ -> Some (Envelope.hash_for_chain last)
              | [] -> find_in_months rest))
    in
    find_in_months months

let create ~base_dir =
  if not (Sys.file_exists base_dir) then Fs_compat.mkdir_p base_dir;
  let latest_hash = load_latest_hash ~base_dir in
  { base_dir; latest_hash }

let base_dir t = t.base_dir

let append t ~category ~payload =
  let entry = Envelope.make ~category ~payload ~prev_hash:t.latest_hash in
  ignore
    (Jsonl_writer.append_dated_jsonl
       ~base_dir:t.base_dir
       ~ts:entry.ts
       (Envelope.to_json entry)
      : Jsonl_writer.dated_path);
  t.latest_hash <- Some (Envelope.hash_for_chain entry);
  entry

let read_all_entries t =
  if not (Sys.file_exists t.base_dir) then []
  else if not (Sys.is_directory t.base_dir) then []
  else
    let entries = ref [] in
    let months =
      Sys.readdir t.base_dir
      |> Array.to_list
      |> List.filter (fun s -> String.length s = 7 && s.[4] = '-')
      |> List.sort String.compare
    in
    List.iter (fun m ->
      let m_dir = Filename.concat t.base_dir m in
      if Sys.is_directory m_dir then begin
        let days =
          Sys.readdir m_dir
          |> Array.to_list
          |> List.filter (fun s -> Filename.check_suffix s ".jsonl")
          |> List.sort String.compare
        in
        List.iter (fun d ->
          let path = Filename.concat m_dir d in
          List.iter (fun e -> entries := e :: !entries) (read_jsonl_file path)
        ) days
      end
    ) months;
    List.rev !entries

let recent t ~n =
  let all = read_all_entries t in
  let len = List.length all in
  if len <= n then all
  else
    let rec drop k l =
      if k <= 0 then l
      else match l with
        | [] -> []
        | _ :: r -> drop (k - 1) r
    in
    drop (len - n) all

let since t ~ts =
  read_all_entries t
  |> List.filter (fun (e : Envelope.t) -> e.ts >= ts)

let verify_chain entries =
  let rec check idx prev = function
    | [] -> Ok ()
    | (e : Envelope.t) :: rest ->
      if e.prev_hash <> prev then
        Error (idx, Printf.sprintf "prev_hash mismatch at index %d" idx)
      else
        let h = Envelope.hash_for_chain e in
        check (idx + 1) (Some h) rest
  in
  check 0 None entries
