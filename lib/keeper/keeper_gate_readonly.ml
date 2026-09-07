(** Pure static observation classification for the external-effect Gate.

    A missing static proof sends the request to the existing boxed execution
    or configured Judge path. Git diff-family commands may run configured
    helpers or write an output file, and a global configuration override can
    change the effect of an otherwise observational command. Their reasons
    remain typed through argv, Shell IR and the request projection.

    This bounded Git correction retains the established policy for other
    commands; it is not a complete effect proof for every Unix/Git option. *)

type git_command = Diff | Log | Show | Grep | Reflog | Whatchanged | Blame | Annotate

type observation_reason =
  | Git_configuration_override
  | Git_command_requires_execution of git_command
  | Unproven_request

type classification =
  | Static_observation
  | Needs_observation of observation_reason

let git_command_name = function
  | Diff -> "diff"
  | Log -> "log"
  | Show -> "show"
  | Grep -> "grep"
  | Reflog -> "reflog"
  | Whatchanged -> "whatchanged"
  | Blame -> "blame"
  | Annotate -> "annotate"
;;

let classification_to_yojson = function
  | Static_observation -> `Assoc [ "kind", `String "static_observation" ]
  | Needs_observation reason ->
    let reason_fields =
      match reason with
      | Git_configuration_override -> [ "kind", `String "git_configuration_override" ]
      | Git_command_requires_execution command ->
        [ "kind", `String "git_command_requires_execution"
        ; "command", `String (git_command_name command)
        ]
      | Unproven_request -> [ "kind", `String "unproven_request" ]
    in
    `Assoc
      [ "kind", `String "needs_observation"
      ; "reason", `Assoc reason_fields
      ]
;;

let static_if proven =
  if proven then Static_observation else Needs_observation Unproven_request
;;

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
    (* Added 2026-09-05 from two days of judged requests: [true] closes a
       [read || true] line (6), [base64] decodes or encodes what it is given
       (4), [jq] has no builtin that writes a file (2), [id] and [uptime]
       print (1 each). None takes an argument that writes. *)
  ; "true"; "false"; "base64"; "jq"; "id"; "uptime"
  ]

(* The existing static Git policy outside this correction. Diff-family,
   helper-capable and reflog commands are handled separately below, never
   admitted by this table merely because their command name sounds like a read. *)
let git_read_subcommands =
  [ "status"; "describe"; "shortlog"; "rev-parse"; "rev-list"; "merge-base"; "cherry"
  ; "ls-files"; "ls-remote"; "ls-tree"; "cat-file"; "name-rev"
  ]

(* git-diff/git-log document --output and external helpers. git-grep may
   invoke a pager; reflog includes write/delete/expire actions. Whatchanged
   shares log's machinery, and builtin/blame.c enables textconv for both
   blame and annotate. Absence of a flag on this argv proves none of those
   repository-configured effects absent.
   Sources: git-scm.com/docs/{git-diff,git-log,git-grep,git-reflog,git-whatchanged};
   github.com/git/git/blob/v2.50.1/builtin/blame.c (allow_textconv). *)
let git_command_requiring_execution = function
  | "diff" -> Some Diff
  | "log" -> Some Log
  | "show" -> Some Show
  | "grep" -> Some Grep
  | "reflog" -> Some Reflog
  | "whatchanged" -> Some Whatchanged
  | "blame" -> Some Blame
  | "annotate" -> Some Annotate
  | _ -> None
;;

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
   here rather than only the explicit method flags.

   This includes [graphql] subcommands carrying a query via [-f]/[--field]:
   measured 2026-09-05, `gh api graphql -f query={ viewer { login } }` was
   deferred to the judge and, once approved, exited 0 with pure read data
   ({"viewer":{"login":…}}, 779ms) — the read itself is real. Deciding
   read-ness from the query text would mean parsing GraphQL (queries and
   mutations share one POST endpoint), which is a string classifier over an
   open language and exactly what this table refuses to become. A field flag
   therefore stays a write-shaped request and keeps its judge turn, whatever
   the query says. *)
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
let git_global_flag_with_value = [ "-C"; "--git-dir"; "--work-tree" ]

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

(* [sed] is deliberately not fast-pathed. Its write ([w]/[W]) and execute
   ([e]) verbs live in the script argument, not in a flag, so no flag
   denylist can prove a [sed] invocation observation-only -- [sed 's/a/b/e' f]
   runs a shell and [sed 'w /path' f] writes a file, both with no [-i]. It
   falls through to the configured judge like any unclassified command. *)

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

(* Decode a long-option token at '=' before comparing its exact name.
   This is Git's --config-env=<name>=<envvar> syntax, not a substring search
   over a command or the configuration value. Unknown option spellings stay
   unproven. In particular, Git does not accept global -cVALUE. *)
let option_name token =
  match String.index_opt token '=' with
  | None -> token
  | Some index -> String.sub token 0 index
;;

let classify_git_argv argv =
  let rec globals = function
    | "-c" :: _ -> Needs_observation Git_configuration_override
    | flag :: _ when String.equal (option_name flag) "--config-env" ->
      Needs_observation Git_configuration_override
    | flag :: rest when List.mem flag git_global_flag_with_value ->
      (match rest with
       | [] -> Needs_observation Unproven_request
       | _value :: tail -> globals tail)
    | flag :: rest when List.mem flag git_global_standalone -> globals rest
    | sub :: rest ->
      (match git_command_requiring_execution sub with
       | Some command -> Needs_observation (Git_command_requires_execution command)
       | None ->
         static_if
           (match sub with
            | "branch" -> List.for_all (fun flag -> List.mem flag git_branch_listing_flags) rest
            | "tag" ->
              List.for_all (fun flag -> String.equal flag "-l" || String.equal flag "--list" || String.starts_with ~prefix:"-n" flag) rest
            | "remote" -> rest = [] || rest = [ "-v" ] || rest = [ "--verbose" ]
            | sub -> List.mem sub git_read_subcommands))
    | [] -> Needs_observation Unproven_request
  in
  globals argv
;;

let classify_argv argv =
  match argv with
  | [] | "" :: _ -> Needs_observation Unproven_request
  | "git" :: rest -> classify_git_argv rest
  | command :: rest ->
    let rejected predicate = List.exists predicate rest in
    static_if
      (match command with
       | "env" -> rest = [] (* [env CMD …] executes CMD; only bare [env] prints. *)
       | "find" -> not (rejected find_flag_writes_or_execs)
       | "sort" | "diff" -> not (rejected writes_to_file)
       | "rg" -> not (rejected rg_flag_runs_preprocessor)
       | "date" -> not (rejected sets_system_time)
       | "hostname" -> List.for_all (fun flag -> String.length flag > 1 && String.sub flag 0 1 = "-") rest
       (* uniq writes its second operand to a file; one operand is a read. *)
       | "uniq" ->
         List.length (List.filter (fun arg -> String.length arg = 0 || String.sub arg 0 1 <> "-") rest) <= 1
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

(* Environment assignments a simple command may carry without changing what
   it does. The IR already separates them from argv into [simple.Ir.env],
   so the question is only which names are inert. [NO_COLOR=1 gh pr list]
   used to lose its observation fast path to a judge turn that inspected
   nothing the assignment could change.

   Stripping is sound only for names on a closed list. Arbitrary names are
   not inert: PATH=. swaps interpreter lookup; LD_PRELOAD injects code;
   BASH_ENV/ENV run shell startup scripts; GIT_EXTERNAL_DIFF makes a
   [git diff] exec a chosen program; GIT_CONFIG_COUNT with
   GIT_CONFIG_KEY_n/VALUE_n injects arbitrary config (core.pager exec);
   GIT_INDEX_FILE redirects the stat cache [git status] refreshes;
   PAGER/GH_PAGER spawn a process; GIT_SSH_COMMAND swaps the transport. A
   denylist of known-bad names would enumerate an open world; the
   uncertain-goes-to-judge rule this module follows asks instead for a
   closed set of names whose effect is confined to output formatting. *)
let inert_env_assignment_names =
  [ "NO_COLOR"; "CLICOLOR"; "CLICOLOR_FORCE"; "TERM"; "TZ"; "LANG"; "LC_ALL" ]
;;

(* [true] when every assignment the command carries is inert. The names are
   on the closed list above, and [TZ] additionally requires a value that is
   not a tzfile reference: glibc treats a value starting with [:] (or any
   value containing [/]) as a path to open and parse as a timezone file,
   which turns [TZ=:/etc/passwd git log] into a file-existence oracle. A
   bare zone name ([UTC], [Asia/Seoul] is POSIX form, but a value with [/]
   could also be a path) — so the guard is: reject [:] prefix and [/]. *)
let env_assignment_inert (name : string) (value : string) : bool =
  match name with
  | "TZ" ->
    (* Zone abbreviations like [UTC] or [EST5EDT] are inert; anything that
       could name a file is not. *)
    not (String.length value > 0 && value.[0] = ':')
    && not (String.contains value '/')
  | name -> List.mem name inert_env_assignment_names
;;

(* [true] when every assignment the command carries is inert — the names
   are on the closed list above, whatever their values, except [TZ] whose
   value must not be a tzfile reference (see [env_assignment_inert]). *)
let env_assignments_inert (env : (string * Ir.arg) list) : bool =
  List.for_all
    (fun (name, value) ->
      match value with
      | Ir.Lit (v, _) -> env_assignment_inert name v
      | Ir.Concat _ -> false
      | Ir.Var _ -> false)
    env
;;

let classify_simple (simple : Ir.simple) =
  if not (env_assignments_inert simple.Ir.env)
     || not (List.for_all redirect_is_observation simple.Ir.redirects)
  then Needs_observation Unproven_request
  else
    match literals_of_args simple.Ir.args with
    | None -> Needs_observation Unproven_request
    | Some args ->
      let bin = Masc_exec.Exec_program.to_string simple.Ir.bin in
      if String.equal bin shell_directory_step then Static_observation
      else classify_argv (bin :: args)
;;

(* Every stage must have a static proof; the first missing proof supplies
   the execution reason instead of collapsing it to a boolean. *)
let rec classify_ir = function
  | Ir.Simple simple -> classify_simple simple
  | Ir.Pipeline [] -> Needs_observation Unproven_request
  | Ir.Pipeline stages -> classify_stages stages
  | Ir.Sequence { head; tail } -> classify_stages (head :: List.map snd tail)
and classify_stages = function
  | [] -> Static_observation
  | stage :: rest ->
    (match classify_ir stage with
     | Static_observation -> classify_stages rest
     | Needs_observation _ as classification -> classification)
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
  | Shell_gate.Reject _ | Shell_gate.Cannot_parse _ | Shell_gate.Too_complex _ ->
    Needs_observation Unproven_request
;;

(* Mirrors [Keeper_tool_execute_runtime.execute_gate_input]: the command
   lives under the nested [input] as [argv] or [script]. An argv whose
   program is a shell with [-c] is a script in an argv costume
   ([Keeper_tooling.Shell_costume]) and is classified as the script it is,
   because that is what the dispatcher runs. The sandbox labels at the top
   level of the envelope are display/audit data only — the sandbox decision
   reads the typed [sandbox_profile] the request carries, never these
   strings. *)
let classify_command input =
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
          if List.length strings <> List.length items
          then Needs_observation Unproven_request
          else
            (match Keeper_tooling.Shell_costume.of_argv strings with
             | Some costume -> classify_script costume.Keeper_tooling.Shell_costume.script
             | None -> classify_argv strings)
        | _ ->
          (match List.assoc_opt "script" inner with
           | Some (`String script) -> classify_script script
           | _ -> Needs_observation Unproven_request))
     | _ -> Needs_observation Unproven_request)
  | _ -> Needs_observation Unproven_request
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

(* A missing/remote profile cannot turn a static command into an unboxed
   observation request. A command-specific reason still survives that
   profile check, so execution records can say why Git needed the box. *)
let classify_request ~operation ~sandbox_profile ~input =
  match operation with
  | "tool_execute" ->
    (match classify_command input with
     | Needs_observation _ as classification -> classification
     | Static_observation ->
       static_if
         (match sandbox_profile with
          | Some profile -> Keeper_types_profile_sandbox.runs_in_disposable_guest profile
          | None -> false))
  | "network_read" ->
    static_if
      (match network_capability_of_gate_input input with
       | Some capability -> List.mem capability observation_network_capabilities
       | None -> false)
  | _ -> Needs_observation Unproven_request
;;
