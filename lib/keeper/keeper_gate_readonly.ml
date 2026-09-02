(** Deterministic observation-only classification for Keeper tool_execute
    gate requests.

    The configured contextual judge's authority is "the concrete effect's
    safety" — never why the Keeper chose the request
    (config/prompts/judge.effect.md). For one closed class that question has
    a deterministic answer: a shell-less argv (no redirection, pipe, or
    command substitution is expressible) whose command is observation-only,
    running inside the docker sandbox. Those requests are allowed without a
    judgment call and without queueing; everything else — every write-capable
    command, every unknown command, every host-sandbox request, every
    non-tool_execute operation — falls through to the configured gate mode
    unchanged.

    The tables are closed on purpose: admitting a command is a reviewed code
    change, not a configuration knob. When classification is uncertain the
    answer is always [false] — the request goes to the configured path. *)

(* ── Command tables ──────────────────────────────────────────────────── *)

(* Observation-only under argv-only execution: the array is exec'd directly
   with no shell, so each command's only outputs are stdout/stderr and its
   exit status. Commands that acquire a write or exec mode through a flag
   are not listed here; they are guarded case by case in [classify_argv].
   A bare name is required: an argv[0] carrying a path (e.g. "/bin/rm")
   matches no entry and falls through. *)
let observation_commands =
  [ "ls"; "cat"; "head"; "tail"; "wc"; "pwd"; "echo"; "printf"; "date"
  ; "file"; "stat"; "du"; "df"; "whoami"; "uname"; "printenv"
  ; "which"; "basename"; "dirname"; "realpath"; "readlink"
  ; "md5sum"; "sha1sum"; "sha256sum"; "sha512sum"
  ; "cmp"; "column"; "nl"; "tac"; "cut"; "tr"; "grep"
  ]

(* git subcommands that read only, in every argument shape they accept. *)
let git_read_subcommands =
  [ "status"; "diff"; "log"; "show"; "blame"; "annotate"; "reflog"
  ; "describe"; "shortlog"; "rev-parse"; "ls-files"; "ls-remote"
  ; "whatchanged"; "cat-file"; "name-rev"; "grep"
  ]

(* git global options that consume the next argv slot before the
   subcommand. *)
let git_global_flag_with_value = [ "-C"; "-c"; "--git-dir"; "--work-tree" ]

let git_global_standalone =
  [ "--no-pager"; "--no-optional-locks"; "--literal-pathspecs"; "--no-replace-objects" ]
;;

(* git branch is observation-only in its listing shapes; any operand names a
   branch to create or mutate, so only known listing flags pass. *)
let git_branch_listing_flags =
  [ "-a"; "--all"; "-r"; "--remotes"; "-v"; "-vv"; "--verbose"; "--list"
  ; "--show-current"; "-q"; "--no-color"
  ]
;;

(* ── Guard predicates ────────────────────────────────────────────────── *)

let find_flag_writes_or_execs flag =
  String.equal flag "-delete"
  || String.equal flag "-fls"
  || String.starts_with ~prefix:"-exec" flag
  || String.starts_with ~prefix:"-ok" flag
  || String.starts_with ~prefix:"-fprint" flag
;;

let sed_flag_is_in_place flag =
  String.starts_with ~prefix:"-i" flag || String.equal flag "--in-place"
;;

let writes_to_file flag =
  String.equal flag "-o" || String.starts_with ~prefix:"--output" flag
;;

let rg_flag_runs_preprocessor flag =
  String.equal flag "--pre" || String.starts_with ~prefix:"--pre-" flag
;;

let sets_system_time flag =
  String.equal flag "-s" || String.equal flag "--set" || String.starts_with ~prefix:"--set=" flag
;;

(* ── argv classification ─────────────────────────────────────────────── *)

let git_argv_is_read argv =
  let rec skip_globals = function
    | flag :: rest when List.mem flag git_global_flag_with_value ->
      (match rest with [] -> None | _ :: tail -> skip_globals tail)
    | flag :: rest when List.mem flag git_global_standalone -> skip_globals rest
    | sub :: rest -> Some (sub, rest)
    | [] -> None
  in
  match skip_globals argv with
  | None -> false
  | Some ("branch", rest) -> List.for_all (fun flag -> List.mem flag git_branch_listing_flags) rest
  | Some ("tag", rest) ->
    List.for_all (fun flag -> String.equal flag "-l" || String.equal flag "--list" || String.starts_with ~prefix:"-n" flag) rest
  | Some ("remote", rest) -> rest = [] || rest = [ "-v" ] || rest = [ "--verbose" ]
  | Some (sub, _) -> List.mem sub git_read_subcommands
;;

let classify_argv argv =
  match argv with
  | [] | "" :: _ -> false
  | command :: rest ->
    let rejected predicate = List.exists predicate rest in
    (match command with
     | "env" -> rest = [] (* [env CMD …] executes CMD; only bare [env] prints. *)
     | "find" -> not (rejected find_flag_writes_or_execs)
     | "sed" -> not (rejected sed_flag_is_in_place)
     | "sort" | "diff" -> not (rejected writes_to_file)
     | "rg" -> not (rejected rg_flag_runs_preprocessor)
     | "date" -> not (rejected sets_system_time)
     | "hostname" -> List.for_all (fun flag -> String.length flag > 1 && String.sub flag 0 1 = "-") rest
     (* uniq writes its second operand to a file; one operand is a read. *)
     | "uniq" ->
       List.length (List.filter (fun arg -> String.length arg = 0 || String.sub arg 0 1 <> "-") rest) <= 1
     | "git" -> git_argv_is_read rest
     | command -> List.mem command observation_commands)
;;

(* ── Gate request decoding ───────────────────────────────────────────── *)

(* Mirrors [Keeper_tool_execute_runtime.execute_gate_input]: argv lives
   under the nested [input], the sandbox fields sit at the top level. *)
let argv_of_gate_input input =
  match input with
  | `Assoc fields ->
    (match List.assoc_opt "input" fields with
     | Some (`Assoc inner) ->
       (match List.assoc_opt "argv" inner with
        | Some (`List items) ->
          let strings =
            List.filter_map
              (function `String value when value <> "" -> Some value | _ -> None)
              items
          in
          if List.length strings = List.length items then Some strings else None
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let docker_sandbox input =
  match input with
  | `Assoc fields ->
    (match (List.assoc_opt "sandbox_profile" fields, List.assoc_opt "sandbox_target" fields) with
     | Some (`String profile), Some (`String target) ->
       String.equal profile "docker" && String.starts_with ~prefix:"docker" target
     | _ -> false)
  | _ -> false
;;

(* ── network_read ────────────────────────────────────────────────────── *)

(* [network_read] with a capability in this set is observation-only in the
   same deterministic sense as the argv table: it runs in the server
   process and its only output is the response payload — no filesystem,
   no exec.

   [web_search] hands the query to a configured search provider; there is
   no caller-chosen address at all.

   [web_fetch] takes a caller-chosen URL, and the one question that matters
   for it — which address the host process reaches — is answered before a
   byte leaves the process: [Tool_misc_web_fetch] refuses loopback,
   link-local, private-network, unspecified, and localhost destinations on
   the initial URL and on every redirect hop. That check reads the URL
   literally, and a judge handed the same string reads it the same way;
   neither resolves DNS. So the judge could not refuse an address the fetch
   admits, and in practice never did: 2026-09-01..02 the Gate judged 319
   network_read requests, approved 319, denied 0, and each fetch waited a
   median 173 s (p90 447 s) between request and replay for the 98 measured
   after the 09-02 restart. Closed on purpose, like the command tables
   above. *)
let observation_network_capabilities = [ "web_search"; "web_fetch" ]

let network_capability_of_gate_input input =
  match input with
  | `Assoc fields ->
    (match List.assoc_opt "capability" fields with
     | Some (`String value) when value <> "" -> Some value
     | _ -> None)
  | _ -> None
;;

let observation_only_request ~operation ~input =
  (String.equal operation "tool_execute"
   && docker_sandbox input
   && (match argv_of_gate_input input with
       | Some argv -> classify_argv argv
       | None -> false))
  || (String.equal operation "network_read"
      && (match network_capability_of_gate_input input with
          | Some capability ->
            List.mem capability observation_network_capabilities
          | None -> false))
;;
