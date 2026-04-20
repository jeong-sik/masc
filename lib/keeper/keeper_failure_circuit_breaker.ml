(** Keeper Failure Circuit Breaker — detect repeated tool failures and
    inject corrective hints into error responses.

    Tracks consecutive failures per keeper by error class. After
    [threshold] consecutive failures of the same class, appends a
    corrective hint to the error message so the LLM adjusts its
    next tool call.

    Error classes are coarse categories (path_not_found, cwd_not_directory,
    path_not_in_allowed_paths/path_outside_sandbox) — not exact error strings. This prevents
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
    let contains sub = String_util.contains_substring error_msg sub in
    if contains "path_not_found" then Path_not_found
    else if contains "path_not_in_allowed" || contains "path_outside_sandbox" then Path_not_allowed
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

(** A single failure signature captured for diagnostics.
    [fingerprint] is a single-line, size-bounded slice of the raw
    [error_msg] — enough for an operator to recognise the failure mode
    without dumping full payloads into logs. *)
type failure_signature = {
  ts : float;
  cls : error_class;
  fingerprint : string;
}

(** Bounded ring-buffer capacity for [recent_failures]. Matches
    [threshold] so a trip log can always name the three failures that
    caused it. Not exposed — an operator-visible knob would imply a
    policy change, which is out of scope for LT-16-KCB diagnostics. *)
let recent_failures_capacity = 3

type breaker_state = {
  mutable consecutive_class : error_class;
  mutable consecutive_count : int;
  mutable total_tripped : int;
  (* Newest-first; length bounded by [recent_failures_capacity].
     Retained across trips so "cooling" inspection still has context. *)
  mutable recent_failures : failure_signature list;
}

let states : (string, breaker_state) Hashtbl.t = Hashtbl.create 16

(** Collapse an error message into a fingerprint suitable for log lines
    and JSON payloads. Strips newlines/tabs, collapses whitespace runs,
    and truncates to [max_len] characters with an ellipsis marker so the
    original length is still recognisable.

    Not cryptographic — the goal is "operator pattern-matches failures
    across keepers", not uniqueness. *)
let fingerprint_of_error ?(max_len = 120) (error_msg : string) : string =
  let len = String.length error_msg in
  let buf = Buffer.create (min len max_len) in
  let prev_space = ref false in
  let i = ref 0 in
  while !i < len && Buffer.length buf < max_len do
    let c = error_msg.[!i] in
    let is_space = c = ' ' || c = '\t' || c = '\n' || c = '\r' in
    if is_space then begin
      if not !prev_space && Buffer.length buf > 0 then Buffer.add_char buf ' ';
      prev_space := true
    end else begin
      Buffer.add_char buf c;
      prev_space := false
    end;
    incr i
  done;
  let s = Buffer.contents buf in
  (* Trim trailing whitespace injected by the collapse above. *)
  let s =
    let n = String.length s in
    if n > 0 && s.[n - 1] = ' ' then String.sub s 0 (n - 1) else s
  in
  if !i < len then s ^ "…" else s

(** Mutex protecting [states] and every per-keeper [breaker_state].
    Every production path goes through [Keeper_exec_tools.apply_circuit_breaker]
    which runs on whichever keeper fiber handled the tool call — multiple
    keepers execute tools concurrently, so [Hashtbl.find_opt] + conditional
    [Hashtbl.replace] in [get_or_create] is a textbook TOCTOU, and the
    per-record [consecutive_count] increment in [record_failure] is a
    read-modify-write racing against [record_success].  [Eio_guard]
    lets the module still work before the Eio scheduler starts (module
    init, non-Eio tests). *)
let states_mu = Eio.Mutex.create ()
let with_states_rw f = Eio_guard.with_mutex states_mu f
let with_states_ro f = Eio_guard.with_mutex_ro states_mu f

let threshold = 3

(* Caller must hold [states_mu]. *)
let get_or_create_locked keeper_name =
  match Hashtbl.find_opt states keeper_name with
  | Some s -> s
  | None ->
    let s = { consecutive_class = Other; consecutive_count = 0;
              total_tripped = 0; recent_failures = [] } in
    Hashtbl.replace states keeper_name s;
    s

(* Caller must hold [states_mu]. Prepends [sig_] and trims the tail so
   the list never exceeds [recent_failures_capacity]. *)
let push_recent_failure_locked (s : breaker_state)
    (sig_ : failure_signature) : unit =
  let rec take n = function
    | _ when n <= 0 -> []
    | [] -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  s.recent_failures <- take recent_failures_capacity (sig_ :: s.recent_failures)

let signature_to_string (sig_ : failure_signature) : string =
  Printf.sprintf "%s:%s"
    (error_class_to_string sig_.cls) sig_.fingerprint

let signature_to_json (sig_ : failure_signature) : Yojson.Safe.t =
  `Assoc [
    "ts", `Float sig_.ts;
    "class", `String (error_class_to_string sig_.cls);
    "fingerprint", `String sig_.fingerprint;
  ]

let format_recent_failures (sigs : failure_signature list) : string =
  match sigs with
  | [] -> "<none>"
  | _ ->
    (* Oldest-first in the log for reading-order clarity. *)
    let ordered = List.rev sigs in
    let parts =
      List.mapi (fun i s ->
        Printf.sprintf "[%d] %s" (i + 1) (signature_to_string s)
      ) ordered
    in
    String.concat " | " parts

(* ================================================================ *)
(* Record + hint generation                                         *)
(* ================================================================ *)

let record_success ~keeper_name =
  with_states_rw (fun () ->
    let s = get_or_create_locked keeper_name in
    s.consecutive_count <- 0)

let rec record_failure ~keeper_name ~(error_msg : string) : string option =
  let cls = classify_error error_msg in
  let sig_ = {
    ts = Time_compat.now ();
    cls;
    fingerprint = fingerprint_of_error error_msg;
  } in
  with_states_rw (fun () ->
    let s = get_or_create_locked keeper_name in
    push_recent_failure_locked s sig_;
    if cls = s.consecutive_class then
      s.consecutive_count <- s.consecutive_count + 1
    else begin
      s.consecutive_class <- cls;
      s.consecutive_count <- 1
    end;
    if s.consecutive_count >= threshold then begin
      s.total_tripped <- s.total_tripped + 1;
      s.consecutive_count <- 0;
      let tripped = s.total_tripped in
      let recent = s.recent_failures in
      Log.Keeper.warn
        "circuit_breaker tripped for %s: %d consecutive %s failures \
         (total trips: %d) recent=%s"
        keeper_name threshold (error_class_to_string cls) tripped
        (format_recent_failures recent);
      Some (corrective_hint cls keeper_name)
    end else
      None)

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
  | Some hint ->
    (* Try to enrich JSON responses by adding circuit_breaker field.
       If error_msg is valid JSON with an "action" field, replace it.
       Otherwise append as text (fallback for non-JSON errors). *)
    (try
       match Yojson.Safe.from_string error_msg with
       | `Assoc fields ->
         let enriched =
           List.map (fun (k, v) ->
             if k = "action" then (k, `String hint)
             else (k, v)
           ) fields
         in
         let with_breaker =
           ("circuit_breaker", `Bool true) :: enriched
         in
         Yojson.Safe.to_string (`Assoc with_breaker)
       | _ -> error_msg ^ hint
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | _ -> error_msg ^ hint)

(* ================================================================ *)
(* Diagnostics                                                      *)
(* ================================================================ *)

let snapshot_json () : Yojson.Safe.t =
  let entries =
    with_states_ro (fun () ->
      Hashtbl.fold (fun name state acc ->
        let recent_json =
          `List (List.map signature_to_json state.recent_failures)
        in
        `Assoc [
          "keeper", `String name;
          "consecutive_class", `String (error_class_to_string state.consecutive_class);
          "consecutive_count", `Int state.consecutive_count;
          "total_tripped", `Int state.total_tripped;
          "recent_failures", recent_json;
        ] :: acc
      ) states [])
  in
  `List entries

let recent_failures_of ~keeper_name : failure_signature list =
  with_states_ro (fun () ->
    match Hashtbl.find_opt states keeper_name with
    | None -> []
    | Some s -> s.recent_failures)

(* ================================================================ *)
(* Observable display state (LT-16-KCB Phase 1)                     *)
(* ================================================================ *)

type display_state =
  | Clean
  | Warning
  | Cooling

let derive_display_state ~consecutive_count ~total_tripped =
  if consecutive_count > 0 then Warning
  else if total_tripped > 0 then Cooling
  else Clean

let display_state_to_string = function
  | Clean -> "clean"
  | Warning -> "warning"
  | Cooling -> "cooling"

let display_state_of ~keeper_name =
  with_states_ro (fun () ->
    match Hashtbl.find_opt states keeper_name with
    | None -> Clean
    | Some s ->
      derive_display_state
        ~consecutive_count:s.consecutive_count
        ~total_tripped:s.total_tripped)

let classify_snapshot_json (json : Yojson.Safe.t)
  : ((string * display_state) list, string) result =
  match json with
  | `List entries ->
    let acc =
      List.filter_map (fun entry ->
        match entry with
        | `Assoc fields ->
          let name =
            match List.assoc_opt "keeper" fields with
            | Some (`String s) -> Some s
            | _ -> None
          in
          let cc =
            match List.assoc_opt "consecutive_count" fields with
            | Some (`Int n) -> Some n
            | _ -> None
          in
          let tt =
            match List.assoc_opt "total_tripped" fields with
            | Some (`Int n) -> Some n
            | _ -> None
          in
          (match name, cc, tt with
           | Some n, Some c, Some t ->
             Some (n, derive_display_state
                        ~consecutive_count:c
                        ~total_tripped:t)
           | _ -> None)
        | _ -> None
      ) entries
    in
    Ok acc
  | _ ->
    Error "classify_snapshot_json: expected top-level JSON array"
