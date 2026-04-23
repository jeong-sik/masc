(* P11: Command History & Suggest
   Append-only JSONL log of bash executions.  Each keeper gets its own
   history file under [.masc/keeper/<name>/bash_history.jsonl].
   Automatic compaction kicks in above 10 000 entries.

   P15: Repeated Failure Detection
   Analyzes recent history for stuck-loop patterns — same command
   failing repeatedly, high failure rates, or timeout clusters.
   Returns structured JSON that the agent can use to self-correct. *)

type history_entry = {
  ts : float;
  cmd_hash : string;
  cmd_prefix : string;
  semantic_kind : string;
  duration_ms : int;
  success : bool;
}

type failure_pattern =
  | Repeated_failure of { cmd_prefix : string; count : int }
  | High_failure_rate of { recent : int; failures : int; rate : float }
  | Timeout_cluster of { cmd_prefix : string; count : int }

let failure_pattern_to_json = function
  | Repeated_failure { cmd_prefix; count } ->
      `Assoc [
        ("kind", `String "repeated_failure");
        ("cmd_prefix", `String cmd_prefix);
        ("count", `Int count);
        ("suggestion", `String (Printf.sprintf
          "\"%s\" failed %d times in a row — consider a different approach"
          cmd_prefix count));
      ]
  | High_failure_rate { recent; failures; rate } ->
      `Assoc [
        ("kind", `String "high_failure_rate");
        ("recent", `Int recent);
        ("failures", `Int failures);
        ("rate", `Float rate);
        ("suggestion", `String (Printf.sprintf
          "%d/%d recent commands failed (%.0f%%) — review approach"
          failures recent (rate *. 100.0)));
      ]
  | Timeout_cluster { cmd_prefix; count } ->
      `Assoc [
        ("kind", `String "timeout_cluster");
        ("cmd_prefix", `String cmd_prefix);
        ("count", `Int count);
        ("suggestion", `String (Printf.sprintf
          "\"%s\" timed out %d times — increase budget or simplify"
          cmd_prefix count));
      ]

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

(* --- P15: failure pattern detection --- *)

(** Minimum consecutive failures on the same command prefix to trigger
    a [Repeated_failure] warning. *)
let repeated_threshold = 3

(** How many recent entries to consider for rate-based analysis. *)
let rate_window = 20

(** Failure rate above which [High_failure_rate] triggers (0.0–1.0). *)
let rate_threshold = 0.6

(** Minimum consecutive entries with [duration_ms] exceeding 30 000
    (30 s) to flag as [Timeout_cluster]. *)
let timeout_ms = 30_000
let timeout_threshold = 2

let take_last n lst =
  let len = List.length lst in
  if len <= n then lst
  else drop (len - n) lst

(** Check if [prefix] appears to be a test runner command. *)
let is_test_prefix prefix =
  let l = String.lowercase_ascii prefix in
  String_util.contains_substring l "test"
  || String_util.contains_substring l "pytest"
  || String_util.contains_substring l "cargo test"
  || String_util.contains_substring l "dune runtest"
  || String_util.contains_substring l "npm test"

(** Walk the most recent entries and return all detected failure patterns.
    Returns [] when there is nothing to report (no file, empty, or healthy). *)
let failure_insight ~base_path ~keeper_name =
  let path, _ = history_path ~base_path ~keeper_name in
  if not (Sys.file_exists path) then []
  else
    let entries = load_entries path in
    let recent = take_last rate_window entries in
    if recent = [] then []
    else begin
      let patterns = ref [] in

      (* 1. Repeated failure: same cmd_prefix, consecutive failures *)
      let rec count_consecutive_failures prefix = function
        | [] -> 0
        | e :: rest when e.cmd_prefix = prefix && not e.success ->
            1 + count_consecutive_failures prefix rest
        | _ -> 0
      in
      let rev_recent = List.rev recent in
      (match rev_recent with
       | e :: _ when not e.success ->
           let n = count_consecutive_failures e.cmd_prefix rev_recent in
           if n >= repeated_threshold then
             patterns :=
               Repeated_failure { cmd_prefix = e.cmd_prefix; count = n }
               :: !patterns
       | _ -> ());

      (* 2. High failure rate across recent window *)
      let total = List.length recent in
      let failures = List.length (List.filter (fun e -> not e.success) recent) in
      let rate = float_of_int failures /. float_of_int total in
      if total >= 5 && rate >= rate_threshold then
        patterns :=
          High_failure_rate { recent = total; failures; rate }
          :: !patterns;

      (* 3. Timeout cluster: same prefix, consecutive slow entries *)
      let rec count_consecutive_timeouts prefix = function
        | [] -> 0
        | e :: rest
          when e.cmd_prefix = prefix
               && e.duration_ms >= timeout_ms ->
            1 + count_consecutive_timeouts prefix rest
        | _ -> 0
      in
      (match rev_recent with
       | e :: _ when e.duration_ms >= timeout_ms ->
           let n = count_consecutive_timeouts e.cmd_prefix rev_recent in
           if n >= timeout_threshold then
             patterns :=
               Timeout_cluster { cmd_prefix = e.cmd_prefix; count = n }
               :: !patterns
       | _ -> ());

      List.rev !patterns
    end
