(** Deterministic observation-only classification for Keeper tool_execute
    gate requests.

    The configured contextual judge's authority is "the concrete effect's
    safety" — never why the Keeper chose the request
    (config/prompts/judge.md, slot effect). For one closed class that question has
    a deterministic answer: a shell-less argv (no redirection, pipe, or
    command substitution is expressible) whose command is observation-only,
    running inside a per-keeper disposable guest (docker container or
    microvm). Those requests are allowed without a
    judgment call and without queueing; everything else — every write-capable
    command, every unknown command, every host-sandbox request, every
    non-tool_execute operation — falls through to the configured gate mode
    unchanged.

    The tables are closed on purpose: admitting a command is a reviewed code
    change, not a configuration knob. When classification is uncertain the
    answer is always [false] — the request goes to the configured path.

    The sandbox question is answered by the typed [sandbox_profile] the gate
    request carries, through
    [Keeper_types_profile_sandbox.runs_in_disposable_guest] — never by
    comparing wire strings. Only per-keeper disposable guests qualify. A
    microvm guest runs its own Linux kernel behind the hypervisor with
    --cap-drop ALL, --read-only and Network_none by default, and the exec
    shim spawns the payload with [Unix.execvpe] — argv, no shell — so the
    premise "shell-less observation-only argv inside a disposable guest"
    holds at least as strongly as under docker. Remote_ssh is transport-only
    (its container knobs are not reproduced and the network is inherited),
    so it stays with the judge. *)

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

(* git subcommands that read only, in every argument shape they accept.
   [merge-base], [rev-list] and [cherry] were added 2026-09-05: over the two
   days before, 21 judged requests carried one of them as a stage, and
   [git -C clone-probe rev-list --count HEAD..origin/main] was the first call
   a microvm keeper sent to the judge after the RFC-0421 restart. None of the
   three has a flag that writes. *)
let git_read_subcommands =
  [ "status"; "diff"; "log"; "show"; "blame"; "annotate"; "reflog"
  ; "describe"; "shortlog"; "rev-parse"; "rev-list"; "merge-base"; "cherry"
  ; "ls-files"; "ls-remote"; "ls-tree"
  ; "whatchanged"; "cat-file"; "name-rev"; "grep"
  ]

(* gh subcommands that only read, keyed by their family. A family is listed
   with the exact verbs that read; every other verb of that family — and every
   family not listed — falls through to the judge. [pr checkout] and [repo
   clone] write the working tree, [pr merge]/[create]/[comment] write on
   GitHub, and [auth login] writes credentials, so none of them appear.

   The network read itself is not what the judge is for: [git ls-remote] and
   the web_fetch capability are already admitted here, and they carry the same
   identity to the same kind of endpoint. What the judge answers is whether an
   effect lands, and a listed verb lands none. *)
(** The gh verbs that only read, keyed by family. Closed on purpose: a verb
    that is not listed goes to the judge, and admitting one is a reviewed
    change here rather than a configuration knob. *)
let gh_read_verbs_by_family =
  [ "pr", [ "list"; "view"; "diff"; "checks"; "status" ]
  ; "issue", [ "list"; "view"; "status" ]
  ; "run", [ "list"; "view" ]
  ; "repo", [ "view"; "list" ]
  ; "release", [ "list"; "view" ]
  ; "workflow", [ "list"; "view" ]
  ; "label", [ "list" ]
  ; "cache", [ "list" ]
  ; "gist", [ "list"; "view" ]
  ; "search", [ "prs"; "issues"; "repos"; "code"; "commits" ]
  ; "auth", [ "status" ]
  ]

(* [--web] leaves the guest: it opens a browser on the host. Nothing else in
   the read verbs takes an argument that writes. *)
let gh_flag_leaves_the_guest flag = String.equal flag "--web" || String.equal flag "-w"

(* [gh api] is a GET only while nothing on the line makes it anything else.
   A field flag alone flips the method to POST, which is why they are refused
   here rather than only the explicit method flags. *)
let gh_api_flag_writes flag =
  List.mem flag
    [ "-X"; "--method"; "-f"; "--raw-field"; "-F"; "--field"; "--input" ]
  || String.starts_with ~prefix:"-X" flag
  || String.starts_with ~prefix:"--method=" flag
  || String.starts_with ~prefix:"--field=" flag
  || String.starts_with ~prefix:"--raw-field=" flag
  || String.starts_with ~prefix:"--input=" flag

let gh_argv_is_read argv =
  match argv with
  | [] -> false
  | "api" :: rest ->
    rest <> []
    && not (List.exists (fun flag -> gh_api_flag_writes flag || gh_flag_leaves_the_guest flag) rest)
  | family :: verb :: rest -> (
    match List.assoc_opt family gh_read_verbs_by_family with
    | None -> false
    | Some verbs ->
      List.mem verb verbs
      && not (List.exists gh_flag_leaves_the_guest rest))
  | [ _ ] -> false
;;

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
     | "gh" -> gh_argv_is_read rest
     | command -> List.mem command observation_commands)
;;

(* ── Gate request decoding ───────────────────────────────────────────── *)

(* ── Script classification through the shell IR (RFC-0421) ─────────── *)

module Shell_gate = Masc_exec_command_gate.Shell_command_gate
module Ir = Masc_exec.Shell_ir

(* A script is classified on the IR the same bash-subset parser gives the
   dispatcher, never on the text. The parser resolves what the shell would
   resolve before any program runs — quotes, word boundaries (space and tab
   alike), connectors, pipes, redirects — and names what it cannot decide:
   a glob, a variable, a substitution, a subshell, a heredoc. Each of those
   is a place where the argv a command receives depends on the guest at run
   time, so each keeps the judge. Everything the IR does show is judged by
   the same closed tables as a real argv. RFC-0404 refused the whole line
   whenever one of those characters appeared; 2026-09-04..05 that sent 94
   scripts whose every stage was an observation command to the judge. *)

(* Only a literal the shell will hand over unchanged counts. A glob may
   expand into flags a guard below inspects; a variable's value is not on
   the line; a concatenation is literal only when every part is. *)
let rec literal_of_arg = function
  | Ir.Lit (_, { Ir.glob = true; _ }) -> None
  | Ir.Lit (text, _) -> Some text
  | Ir.Var _ -> None
  | Ir.Concat parts ->
    let rec join acc = function
      | [] -> Some (String.concat "" (List.rev acc))
      | part :: rest ->
        (match literal_of_arg part with
         | Some text -> join (text :: acc) rest
         | None -> None)
    in
    join [] parts
;;

let rec literals_of_args = function
  | [] -> Some []
  | arg :: rest ->
    (match literal_of_arg arg, literals_of_args rest with
     | Some text, Some texts -> Some (text :: texts)
     | None, _ | _, None -> None)
;;

(* A redirect is observation when nothing lands on a file: an fd joined to
   another fd (2>&1), a file read as stdin, or bytes discarded into the
   sink. A write or append to any other target is a filesystem effect. *)
let redirect_is_observation = function
  | Masc_exec.Redirect_scope.Fd_to_fd _ -> true
  | Masc_exec.Redirect_scope.File { mode = Masc_exec.Redirect_scope.Read; _ } -> true
  | Masc_exec.Redirect_scope.File
      { mode = Masc_exec.Redirect_scope.Write | Masc_exec.Redirect_scope.Append
      ; target
      ; _
      } ->
    (match target with
     | Masc_exec.Redirect_scope.In_command_namespace scope
     | Masc_exec.Redirect_scope.On_this_host { as_written = scope; _ } ->
       Masc_exec.Path_scope.is_discard_sink scope)
  | Masc_exec.Redirect_scope.Literal _ -> false
;;

(* [cd] is the shell's own step: it moves the directory of the shell that
   runs the rest of the line and of nothing else, so a line that changes
   directory before observing is still an observation. *)
let shell_directory_step = "cd"

let classify_simple (simple : Ir.simple) =
  simple.Ir.env = []
  && List.for_all redirect_is_observation simple.Ir.redirects
  &&
  match literals_of_args simple.Ir.args with
  | None -> false
  | Some args ->
    let bin = Masc_exec.Exec_program.to_string simple.Ir.bin in
    String.equal bin shell_directory_step || classify_argv (bin :: args)
;;

(* Every stage of a pipeline and every command of a sequence must classify:
   [a && b], [a; b], [a || b] and [a | b] each run every named command in
   some path, and the connector decides nothing about effects. *)
let rec classify_ir = function
  | Ir.Simple simple -> classify_simple simple
  | Ir.Pipeline stages -> stages <> [] && List.for_all classify_ir stages
  | Ir.Sequence { head; tail } ->
    classify_ir head && List.for_all (fun (_, part) -> classify_ir part) tail
;;

(* The dispatcher's own syntax policy: pipes and redirects are representable,
   and the tables above decide what each stage may do with them. The sandbox
   context is evidence only inside the parser; the sandbox decision for this
   request is the typed [sandbox_profile] the caller checks. [decide_raw]
   writes no log line, so classifying here leaves no trace of a dispatch
   that did not happen. *)
let classify_script script =
  match
    Shell_gate.decide_raw
      ~text:script
      ~syntax_policy:{ Shell_gate.redirect_allowed = true; allow_pipes = true }
      ~sandbox:Shell_gate.host_sandbox
  with
  | Shell_gate.Allow { Shell_gate.ast; _ } -> classify_ir ast
  | Shell_gate.Reject _ | Shell_gate.Cannot_parse _ | Shell_gate.Too_complex _ -> false
;;

(* Mirrors [Keeper_tool_execute_runtime.execute_gate_input]: the command
   lives under the nested [input] as [argv] or [script]. An argv whose
   program is a shell with [-c] is a script in an argv costume
   ([Keeper_tooling.Shell_costume]) and is classified as the script it is,
   because that is what the dispatcher runs. The sandbox labels at the top
   level of the envelope are display/audit data only — the sandbox decision
   reads the typed [sandbox_profile] the request carries, never these
   strings. *)
let command_is_observation input =
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
          List.length strings = List.length items
          &&
          (match Keeper_tooling.Shell_costume.of_argv strings with
           | Some costume -> classify_script costume.Keeper_tooling.Shell_costume.script
           | None -> classify_argv strings)
        | _ ->
          (match List.assoc_opt "script" inner with
           | Some (`String script) -> classify_script script
           | _ -> false))
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

let observation_only_request ~operation ~sandbox_profile ~input =
  (String.equal operation "tool_execute"
   && (match sandbox_profile with
       | Some profile -> Keeper_types_profile_sandbox.runs_in_disposable_guest profile
       | None -> false)
   && command_is_observation input)
  || (String.equal operation "network_read"
      && (match network_capability_of_gate_input input with
          | Some capability ->
            List.mem capability observation_network_capabilities
          | None -> false))
;;
