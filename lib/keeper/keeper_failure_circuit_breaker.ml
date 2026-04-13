(** Keeper Failure Circuit Breaker — detect repeated tool failures and
    inject corrective hints into error responses.

    Tracks consecutive failures per keeper by error class. After
    [threshold] consecutive failures of the same class, appends a
    corrective hint to the error message so the LLM adjusts its
    next tool call.

    Error classes are coarse categories (path_not_found, cwd_not_directory,
    path_not_in_allowed_paths) — not exact error strings. This prevents
    near-miss variants from resetting the counter. *)

(* ================================================================ *)
(* Error classification                                             *)
(* ================================================================ *)

type error_class =
  | Path_not_found
  | Path_not_allowed
  | Cwd_not_directory
  | Shell_exit_nonzero
  | Other

let classify_error (error_msg : string) : error_class =
  if String.length error_msg = 0 then Other
  else
    let contains sub = try
      let _ = Str.search_forward (Str.regexp_string sub) error_msg 0 in
      true
    with Not_found -> false
    in
    if contains "path_not_found" then Path_not_found
    else if contains "path_not_in_allowed" then Path_not_allowed
    else if contains "cwd_not_directory" then Cwd_not_directory
    else if contains "No such file or directory" then Path_not_found
    else if contains "exit" && contains "code" then Shell_exit_nonzero
    else Other

let error_class_to_string = function
  | Path_not_found -> "path_not_found"
  | Path_not_allowed -> "path_not_allowed"
  | Cwd_not_directory -> "cwd_not_directory"
  | Shell_exit_nonzero -> "shell_exit_nonzero"
  | Other -> "other"

(* ================================================================ *)
(* Per-keeper state                                                  *)
(* ================================================================ *)

type breaker_state = {
  mutable consecutive_class : error_class;
  mutable consecutive_count : int;
  mutable total_tripped : int;
}

let states : (string, breaker_state) Hashtbl.t = Hashtbl.create 16

let threshold = 3

let get_or_create keeper_name =
  match Hashtbl.find_opt states keeper_name with
  | Some s -> s
  | None ->
    let s = { consecutive_class = Other; consecutive_count = 0;
              total_tripped = 0 } in
    Hashtbl.replace states keeper_name s;
    s

(* ================================================================ *)
(* Record + hint generation                                         *)
(* ================================================================ *)

let record_success ~keeper_name =
  let s = get_or_create keeper_name in
  s.consecutive_count <- 0

let record_failure ~keeper_name ~(error_msg : string) : string option =
  let cls = classify_error error_msg in
  let s = get_or_create keeper_name in
  if cls = s.consecutive_class then
    s.consecutive_count <- s.consecutive_count + 1
  else begin
    s.consecutive_class <- cls;
    s.consecutive_count <- 1
  end;
  if s.consecutive_count >= threshold then begin
    s.total_tripped <- s.total_tripped + 1;
    s.consecutive_count <- 0;
    Log.Keeper.warn
      "circuit_breaker tripped for %s: %d consecutive %s failures (total trips: %d)"
      keeper_name threshold (error_class_to_string cls) s.total_tripped;
    Some (corrective_hint cls keeper_name)
  end else
    None

and corrective_hint cls keeper_name =
  let base =
    Printf.sprintf
      "\n\n[CIRCUIT BREAKER] You have failed %d times with the same error class (%s). STOP and change your approach:\n"
      threshold (error_class_to_string cls)
  in
  let specific = match cls with
    | Path_not_found ->
      Printf.sprintf
        "- The file you are looking for does NOT exist. Do NOT guess paths.\n\
         - Run `keeper_shell op=ls` on your playground root first to see what actually exists.\n\
         - Your playground: .masc/playground/%s/\n\
         - Your repos: .masc/playground/%s/repos/ (clone a repo first if empty)\n\
         - NEVER fabricate file paths like lib/ocaml/... — check with ls first."
        keeper_name keeper_name
    | Path_not_allowed ->
      Printf.sprintf
        "- You are trying to access a path outside your allowed roots.\n\
         - Stay inside: .masc/playground/%s/ or allowed workspace paths.\n\
         - Do NOT access the server root or arbitrary directories.\n\
         - Run `keeper_context_status` to see your allowed paths."
        keeper_name
    | Cwd_not_directory ->
      "- The cwd you specified is not a directory. Use `keeper_shell op=ls` to find valid directories.\n\
       - Leave the cwd parameter empty to use your default playground root."
    | Shell_exit_nonzero ->
      "- Your shell command is failing repeatedly. Check the command syntax.\n\
       - Try a simpler command first to verify the tool works.\n\
       - Do NOT retry the exact same failing command."
    | Other ->
      "- You are repeating the same failing action. Try a completely different approach.\n\
       - If stuck, use `keeper_stay_silent` and wait for new context."
  in
  base ^ specific

(* ================================================================ *)
(* Append hint to error message                                     *)
(* ================================================================ *)

let maybe_enrich_error ~keeper_name ~(error_msg : string) : string =
  match record_failure ~keeper_name ~error_msg with
  | None -> error_msg
  | Some hint -> error_msg ^ hint

(* ================================================================ *)
(* Diagnostics                                                      *)
(* ================================================================ *)

let snapshot_json () : Yojson.Safe.t =
  let entries =
    Hashtbl.fold (fun name state acc ->
      `Assoc [
        "keeper", `String name;
        "consecutive_class", `String (error_class_to_string state.consecutive_class);
        "consecutive_count", `Int state.consecutive_count;
        "total_tripped", `Int state.total_tripped;
      ] :: acc
    ) states []
  in
  `List entries
