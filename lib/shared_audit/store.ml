type t = {
  base_dir : string;
  mutable latest_hash : string option;
}

let format_path ~base_dir ~ts =
  let tm = Unix.gmtime ts in
  let yyyy_mm = Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900)
                  (tm.Unix.tm_mon + 1)
  in
  let dd = Printf.sprintf "%02d" tm.Unix.tm_mday in
  Filename.concat (Filename.concat base_dir yyyy_mm) (dd ^ ".jsonl")

let rec mkdir_p dir =
  if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let ensure_dir_exists path = mkdir_p (Filename.dirname path)

let parse_jsonl_line line =
  try Yojson.Safe.from_string line |> Envelope.of_json with
  | Yojson.Json_error msg -> Error msg

let read_jsonl_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let entries = ref [] in
      (try
         while true do
           let line = input_line ic in
           if String.length line > 0 then
             match parse_jsonl_line line with
             | Ok env -> entries := env :: !entries
             | Error _ -> ()
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
  if not (Sys.file_exists base_dir) then mkdir_p base_dir;
  let latest_hash = load_latest_hash ~base_dir in
  { base_dir; latest_hash }

let base_dir t = t.base_dir

let append t ~category ~payload =
  let entry = Envelope.make ~category ~payload ~prev_hash:t.latest_hash in
  let path = format_path ~base_dir:t.base_dir ~ts:entry.ts in
  ensure_dir_exists path;
  let oc = open_out_gen [Open_append; Open_creat; Open_wronly] 0o644 path in
  output_string oc (Yojson.Safe.to_string (Envelope.to_json entry));
  output_char oc '\n';
  close_out oc;
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
