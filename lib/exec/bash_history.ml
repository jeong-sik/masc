(* P11: Command History & Suggest
   Append-only JSONL log of bash executions.  Each keeper gets its own
   history file under [.masc/keeper/<name>/bash_history.jsonl].
   Automatic compaction kicks in above 10 000 entries. *)

type history_entry = {
  ts : float;
  cmd_hash : string;
  cmd_prefix : string;
  semantic_kind : string;
  duration_ms : int;
  success : bool;
}

(* --- helpers --- *)

let close_out_no_err oc =
  try close_out oc with _ -> ()

let close_in_no_err ic =
  try close_in ic with _ -> ()

let mkdir_p path =
  let rec aux built = function
    | [] -> ()
    | comp :: rest ->
        let dir = built ^ "/" ^ comp in
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        aux dir rest
  in
  let parts = String.split_on_char '/' path in
  aux "" parts

(* --- JSON codec --- *)

let entry_to_json e =
  `Assoc
    [
      ("ts", `Float e.ts);
      ("cmd_hash", `String e.cmd_hash);
      ("cmd_prefix", `String e.cmd_prefix);
      ("semantic_kind", `String e.semantic_kind);
      ("duration_ms", `Int e.duration_ms);
      ("success", `Bool e.success);
    ]

let entry_of_json = function
  | `Assoc fields ->
      let get k default =
        List.find_map
          (fun (k', v) -> if k' = k then Some v else None)
          fields
        |> Option.value ~default
      in
      let ts =
        match get "ts" (`Float 0.0) with
        | `Float f -> f
        | _ -> 0.0
      in
      let cmd_hash =
        match get "cmd_hash" (`String "") with `String s -> s | _ -> ""
      in
      let cmd_prefix =
        match get "cmd_prefix" (`String "") with `String s -> s | _ -> ""
      in
      let semantic_kind =
        match get "semantic_kind" (`String "Unknown") with
        | `String s -> s
        | _ -> "Unknown"
      in
      let duration_ms =
        match get "duration_ms" (`Int 0) with `Int i -> i | _ -> 0
      in
      let success =
        match get "success" (`Bool true) with `Bool b -> b | _ -> true
      in
      Some { ts; cmd_hash; cmd_prefix; semantic_kind; duration_ms; success }
  | _ -> None

(* --- path resolution --- *)

let history_path ~base_path ~keeper_name =
  let dir =
    Filename.concat
      (Filename.concat base_path ".masc")
      (Filename.concat "keeper" keeper_name)
  in
  ( Filename.concat dir "bash_history.jsonl",
    fun () ->
      if not (Sys.file_exists dir) then mkdir_p dir )

(* --- hash --- *)

let cmd_hash cmd =
  let hex = Digest.to_hex (Digest.string cmd) in
  String.sub hex 0 12

(* --- I/O --- *)

let max_entries = 10_000
let compact_to = 1_000

let append ~base_path ~keeper_name entry =
  let path, ensure_dir = history_path ~base_path ~keeper_name in
  ensure_dir ();
  let oc = open_out_gen [ Open_wronly; Open_creat; Open_append ] 0o644 path in
  output_string oc (Yojson.Safe.to_string (entry_to_json entry));
  output_char oc '\n';
  close_out_no_err oc

let count_lines path =
  let ic = open_in path in
  let count = ref 0 in
  (try while true do
       let _ = input_line ic in
       incr count
     done
   with End_of_file -> ());
  close_in_no_err ic;
  !count

let load_entries path =
  let ic = open_in path in
  let entries = ref [] in
  (try while true do
       let line = input_line ic in
       match Yojson.Safe.from_string line with
       | exception _ -> ()
       | json ->
           match entry_of_json json with
           | Some e -> entries := e :: !entries
           | None -> ()
     done
   with End_of_file -> ());
  close_in_no_err ic;
  List.rev !entries

let drop n xs =
  let rec aux n = function
    | [] -> []
    | _ :: xs when n > 0 -> aux (n - 1) xs
    | xs -> xs
  in
  aux n xs

(* --- compaction --- *)

let compact ~base_path ~keeper_name =
  let path, _ = history_path ~base_path ~keeper_name in
  if Sys.file_exists path then
    let n = count_lines path in
    if n > max_entries then begin
      let entries = load_entries path in
      let keep = drop (List.length entries - compact_to) entries in
      let oc = open_out path in
      List.iter
        (fun e ->
          output_string oc (Yojson.Safe.to_string (entry_to_json e));
          output_char oc '\n')
        keep;
      close_out_no_err oc
    end

(* --- suggest (query) --- *)

let suggest ~base_path ~keeper_name ~pattern ~limit =
  let path, _ = history_path ~base_path ~keeper_name in
  if not (Sys.file_exists path) then []
  else begin
    let entries = load_entries path in
    let matches =
      List.filter
        (fun e ->
          let plen = String.length pattern in
          let prefix_match =
            String.length e.cmd_prefix >= plen
            && String.sub e.cmd_prefix 0 plen = pattern
          in
          let hash_match =
            String.length e.cmd_hash >= plen
            && String.sub e.cmd_hash 0 plen = pattern
          in
          prefix_match || hash_match)
        entries
    in
    let rec last_n n = function
      | [] -> []
      | xs when n <= 0 -> []
      | xs when List.length xs <= n -> xs
      | _ :: xs -> last_n n xs
    in
    last_n limit matches
  end
