open Keeper_meta_contract

let target_ref_stale_after_s = 900

(* How long the endpoint probe may run: the shim's limit on the payload
   (python start, the walk, and the git reads of every checkout reported) and
   the wait for the endpoint around it. [Repo_git.inspection_timeout_sec]
   budgets git subprocesses on this host, which is different work.
   Measured 2026-11-27 (#35039) on live endpoints, 5 runs per Keeper over 4
   Keepers per backend, uncapped, payload seconds:
                  one checkout at a time    four at a time (this probe)
     microvm      p90 19.0, max 20.5        p90  9.0, max 16.2
     remote_ssh   p90 54.8, max 57.0        p90 13.5, max 29.0
   The slow runs are Keepers at the 32-checkout cap on a cold cache. 40 s
   keeps the slowest run of this probe with room. The runner's own wall limit
   adds the connect (10 s on every endpoint configured today) and 4 s grace:
   54 s. A microvm request first admits the guest, up to
   [guest_state_timeout_sec] (5 s): 59 s, inside the dashboard's 60 s request
   timeout (DEFAULT_MCP_TIMEOUT_MS) that waits on this probe. The absence
   check runs only after a failed probe. *)
let probe_budget_sec = 40.0

(* How long one checkout's git reads may take together. The longest checkout
   in the runs above took 11.8 s (remote_ssh, cold cache, four at a time);
   20 s is that with room. It is below [probe_budget_sec], so a checkout whose
   git does not answer loses its own git fields, read as unread after 20 s,
   while the other workers finish the rest. *)
let checkout_inspection_sec = 20.0

(* Every microvm guest and the remote_ssh container configured on 2026-11-27
   has 4 CPUs ([container list]), and [git status], the bulk of the work,
   is bound by CPU and disk. *)
let inspection_workers = 4

(* Guest admission before the probe and the absence check after a failed one
   each ask the container runtime about one guest ([container inspect], then
   its inventory when inspect does not answer). Neither walks the workspace or
   runs git, so they keep a short budget instead of the probe's.
   [container inspect] on the four running Apple guests, 2026-11-27: n=20,
   median 0.09 s, max 0.20 s. 5 s is what these reads had before the probe got
   its own budget. *)
let guest_state_timeout_sec = 5.0

type remote_origin =
  | Origin_url of string
  | Origin_not_configured
  | Origin_unread

type inspected_checkout =
  { checkout : Keeper_playground_checkouts.checkout
  ; origin : remote_origin
  ; branch : (string, string) result
  ; head : (string, string) result
  ; dirty : (bool * int, string) result
  ; target_ref : string option
  ; upstream_head : string option
  ; target_ref_last_observed_at_unix : int option
  ; ahead : int option
  ; behind : int option
  }

type layout =
  { entries : string list
  ; discovery : Keeper_playground_checkouts.discovery
  }

let probe_script =
  {|\
import os, sys, json, subprocess, time, stat
from collections import deque
from concurrent.futures import ThreadPoolExecutor

# The arguments are built by the OCaml side; a malformed one is its
# defect and ends the probe with a traceback the caller reports.
catalog = json.loads(sys.argv[1])
checkout_budget = int(sys.argv[2])
entry_budget = int(sys.argv[3])
target_ref_stale_after_s = int(sys.argv[4])
mode = sys.argv[5]
if mode not in ('inspect', 'layout'):
    raise ValueError('unknown probe mode')
checkout_inspection_sec = float(sys.argv[6])
inspection_workers = int(sys.argv[7])

def canon_url(u):
    if not u: return ''
    u = u.strip().lower()
    if '@' in u and ':' in u and not u.startswith('http'):
        u = u.split('@', 1)[1].replace(':', '/')
    elif '://' in u:
        u = u.split('://', 1)[1]
    if '@' in u:
        u = u.split('@', 1)[1]
    u = u.rstrip('/')
    if u.endswith('.git'): u = u[:-4]
    return u

catalog_by_url = {}
for repo in catalog:
    u = canon_url(repo.get('url'))
    if u: catalog_by_url[u] = repo

def inspect_git(path):
    # Every git call in this checkout shares one deadline. A call past it
    # is a field that was not read; the other checkouts keep their own.
    deadline = time.monotonic() + checkout_inspection_sec

    def run(args):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        try:
            return subprocess.run(['git', '-C', path] + list(args), capture_output=True, text=True,
                                  timeout=remaining)
        except (subprocess.TimeoutExpired, OSError):
            # No git on the endpoint, or the call ran past the deadline:
            # that field is unavailable, the rest of the row still reports.
            return None

    def git(*args):
        r = run(args)
        return r.stdout.strip() if r is not None and r.returncode == 0 else None

    # git remote get-url exits 2 only for "no such remote", and it needs a
    # repository, so an unusable one (dubious ownership, a broken .git) dies
    # with 128 instead. The host lane reads the same command the same way
    # (Repo_git.get_origin_url). Any outcome but 0 or 2 is a read that did
    # not happen.
    origin = None
    origin_state = 'unavailable'
    r = run(['remote', 'get-url', 'origin'])
    if r is not None:
        if r.returncode == 0 and r.stdout.strip():
            origin = r.stdout.strip()
            origin_state = 'present'
        elif r.returncode == 2:
            origin_state = 'missing'
    branch = git('symbolic-ref', '--short', '-q', 'HEAD') or git('rev-parse', '--abbrev-ref', 'HEAD')
    head = git('rev-parse', 'HEAD')
    status = git('--no-optional-locks', 'status', '--porcelain=v1', '--untracked-files=normal')
    dirty = None
    changed_files = None
    if status is not None:
        lines = [l for l in status.splitlines() if not l.startswith('!!')]
        changed_files = len(lines)
        dirty = changed_files > 0

    upstream_head = None
    ahead = None
    behind = None
    target_ref = None
    target_ref_last_observed_at_unix = None

    matched_repo = None
    if origin:
        matched_repo = catalog_by_url.get(canon_url(origin))

    if matched_repo:
        def_branch = matched_repo.get('default_branch', 'main')
        target_ref = 'origin/' + def_branch
        upstream_head = git('rev-parse', target_ref)
        if upstream_head:
            counts = git('rev-list', '--left-right', '--count', f'{target_ref}...HEAD')
            if counts:
                parts = counts.split()
                if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
                    behind = int(parts[0])
                    ahead = int(parts[1])
            if behind == 0 and ahead == 0:
                reflog = git('reflog', 'show', '-1', '--date=unix', '--format=%gd', target_ref)
                if reflog and '@{' in reflog and reflog.endswith('}'):
                    moved = reflog.rsplit('@{', 1)[1][:-1]
                    if moved.isdigit():
                        target_ref_last_observed_at_unix = int(moved)
                if target_ref_last_observed_at_unix is None or \
                   time.time() - target_ref_last_observed_at_unix > target_ref_stale_after_s:
                    common = git('rev-parse', '--path-format=absolute', '--git-common-dir')
                    if common:
                        common = os.path.realpath(common)
                        receipt_path = os.path.join(common, 'masc-target-ref-observation.json')
                        try:
                            with open(receipt_path, encoding='utf-8') as source:
                                receipt = json.load(source)
                            observed = receipt.get('observed_at_unix')
                            if receipt.get('common_dir') == common and \
                               receipt.get('target_ref') == target_ref and \
                               receipt.get('oid') == upstream_head and \
                               canon_url(receipt.get('origin_url')) == canon_url(origin) and \
                               type(observed) is int and observed > 0:
                                target_ref_last_observed_at_unix = max(
                                    target_ref_last_observed_at_unix or 0, observed)
                        except (OSError, ValueError, AttributeError):
                            pass

    return {
        'origin': origin,
        'origin_state': origin_state,
        'branch': branch,
        'head': head,
        'dirty': dirty,
        'changed_files': changed_files,
        'target_ref': target_ref,
        'upstream_head': upstream_head,
        'target_ref_last_observed_at_unix': target_ref_last_observed_at_unix,
        'ahead': ahead,
        'behind': behind
    }

root = '.'
checkouts = []
paths = {}
queue = deque([''])
scanned = 0
limit = None
unreadable = None
root_entries = sorted(os.listdir(root)) if mode == "layout" else None

def git_link_at(path):
    try:
        kind = os.lstat(os.path.join(path, '.git')).st_mode
    except FileNotFoundError:
        return None
    if stat.S_ISDIR(kind): return 'directory'
    if stat.S_ISREG(kind): return 'pointer_file'
    return None

def record_checkout(path, rel, git_link):
    checkouts.append({
        'relative_path': rel or '.',
        'name': os.path.basename(os.path.abspath(path)),
        'git_link': git_link
    })
    paths[rel or '.'] = path

root_git_link = git_link_at(root)
if root_git_link:
    record_checkout(root, '', root_git_link)
else:
    # Past either budget by one, as the host walk is: the extra find is
    # what says the budget was exhausted rather than exactly met.
    while queue and len(checkouts) <= checkout_budget and scanned <= entry_budget:
        rel = queue.popleft()
        full = os.path.join(root, rel) if rel else root
        try:
            entries = root_entries if not rel and root_entries is not None else sorted(os.listdir(full))
        except OSError as error:
            if unreadable is None:
                unreadable = {'kind': 'directory_unreadable',
                              'relative_path': rel, 'detail': str(error)}
            continue
        scanned += len(entries)
        if scanned > entry_budget:
            break
        for e in entries:
            if e in ('.', '..'): continue
            c_full = os.path.join(full, e)
            # lstat never follows directory or .git symlinks out of the tree.
            kind = os.lstat(c_full).st_mode
            if stat.S_ISDIR(kind):
                c_rel = os.path.join(rel, e) if rel else e
                git_link = git_link_at(c_full)
                if git_link:
                    record_checkout(c_full, c_rel, git_link)
                    if len(checkouts) > checkout_budget:
                        break
                    continue
                queue.append(c_rel)

if len(checkouts) > checkout_budget:
    limit = {'kind': 'checkout_budget_exhausted', 'budget': checkout_budget}
elif scanned > entry_budget:
    limit = {'kind': 'entry_budget_exhausted', 'scanned': scanned, 'budget': entry_budget}
elif unreadable is not None:
    limit = unreadable

checkouts.sort(key=lambda c: c['relative_path'])
checkouts = checkouts[:checkout_budget]

# Git runs after the walk, only in the checkouts that are reported (the one
# found past the budget is never inspected), and in a few checkouts at a
# time. Each checkout's reads depend on nothing outside it, so the rows are
# the ones a one-at-a-time pass would print, in the same order.
if mode == 'inspect' and checkouts:
    with ThreadPoolExecutor(max_workers=inspection_workers) as pool:
        inspections = pool.map(inspect_git, [paths[c['relative_path']] for c in checkouts])
        for row, info in zip(checkouts, inspections):
            row.update(info)

result = {
    'checkouts': checkouts,
    'scanned': scanned,
    'limit': limit
}
if mode == "layout":
    result["entries"] = root_entries
print(json.dumps(result))
|}

open Result.Syntax

let json_kind : Yojson.Safe.t -> string = function
  | `Null -> "null"
  | `Bool _ -> "a boolean"
  | `Int _ | `Intlit _ -> "an integer"
  | `Float _ -> "a number"
  | `String _ -> "a string"
  | `List _ -> "a list"
  | `Assoc _ -> "an object"

let wrong_shape key expected json =
  Error (Printf.sprintf "%s: expected %s, got %s" key expected (json_kind json))

let object_fields what : Yojson.Safe.t -> ((string * Yojson.Safe.t) list, string) result
  = function
  | `Assoc fields -> Ok fields
  | other -> wrong_shape what "an object" other

let field key fields = Option.value (List.assoc_opt key fields) ~default:`Null

let string_field key fields =
  match field key fields with
  | `String s -> Ok s
  | other -> wrong_shape key "a string" other

let int_field key fields =
  match field key fields with
  | `Int i -> Ok i
  | other -> wrong_shape key "an integer" other

(* The probe prints [null] for what a git call could not answer. *)
let optional_string_field key fields =
  match field key fields with
  | `String s -> Ok (Some s)
  | `Null -> Ok None
  | other -> wrong_shape key "a string or null" other

let optional_int_field key fields =
  match field key fields with
  | `Int i -> Ok (Some i)
  | `Null -> Ok None
  | other -> wrong_shape key "an integer or null" other

let optional_bool_field key fields =
  match field key fields with
  | `Bool b -> Ok (Some b)
  | `Null -> Ok None
  | other -> wrong_shape key "a boolean or null" other

(* The two spellings the probe prints for how [.git] is linked. *)
let git_link_of_string = function
  | "directory" -> Ok Keeper_playground_checkouts.Git_directory
  | "pointer_file" -> Ok Keeper_playground_checkouts.Git_pointer_file
  | other -> Error (Printf.sprintf "git_link: unknown value %S" other)

let parse_limit : Yojson.Safe.t -> (Keeper_playground_checkouts.limit option, string) result
  = function
  | `Null -> Ok None
  | json ->
    let* fields = object_fields "limit" json in
    let* kind = string_field "kind" fields in
    (match kind with
     | "entry_budget_exhausted" ->
       let* scanned = int_field "scanned" fields in
       let* budget = int_field "budget" fields in
       Ok (Some (Keeper_playground_checkouts.Entry_budget_exhausted { scanned; budget }))
     | "checkout_budget_exhausted" ->
       let* budget = int_field "budget" fields in
       Ok (Some (Keeper_playground_checkouts.Checkout_budget_exhausted { budget }))
     | "directory_unreadable" ->
       let* relative_path = string_field "relative_path" fields in
       let* detail = string_field "detail" fields in
       Ok (Some (Keeper_playground_checkouts.Directory_unreadable { relative_path; detail }))
     | other -> Error (Printf.sprintf "limit: unknown kind %S" other))

let parse_checkout_path ~root json =
  let* fields = object_fields "checkout" json in
  let* relative_path = string_field "relative_path" fields in
  let* name = string_field "name" fields in
  let* git_link =
    let* raw = string_field "git_link" fields in
    git_link_of_string raw
  in
  let absolute_path =
    if String.equal relative_path "."
    then root
    else Filename.concat root relative_path
  in
  let checkout : Keeper_playground_checkouts.checkout =
    { relative_path; absolute_path; name; git_link }
  in
  Ok checkout

let parse_checkout ~root json =
  let* fields = object_fields "checkout" json in
  let* checkout = parse_checkout_path ~root json in
  let* origin =
    let* state = string_field "origin_state" fields in
    let* url = optional_string_field "origin" fields in
    match state, url with
    | "present", Some url -> Ok (Origin_url url)
    | "missing", None -> Ok Origin_not_configured
    | "unavailable", None -> Ok Origin_unread
    | ("present" | "missing" | "unavailable"), _ ->
      Error (Printf.sprintf "origin_state %S disagrees with origin" state)
    | other, _ -> Error (Printf.sprintf "origin_state: unknown value %S" other)
  in
  let* branch =
    let* branch = optional_string_field "branch" fields in
    Ok (Option.to_result ~none:"branch unavailable" branch)
  in
  let* head =
    let* head = optional_string_field "head" fields in
    Ok (Option.to_result ~none:"head unavailable" head)
  in
  (* Both come from the one status read, so the probe prints both or neither. *)
  let* dirty =
    let* dirty = optional_bool_field "dirty" fields in
    let* changed_files = optional_int_field "changed_files" fields in
    match dirty, changed_files with
    | Some dirty, Some changed_files -> Ok (Ok (dirty, changed_files))
    | None, None -> Ok (Error "status unavailable")
    | Some _, None | None, Some _ ->
      Error "dirty and changed_files come from one status read; only one is present"
  in
  let* target_ref = optional_string_field "target_ref" fields in
  let* upstream_head = optional_string_field "upstream_head" fields in
  let* target_ref_last_observed_at_unix =
    optional_int_field "target_ref_last_observed_at_unix" fields in
  let* ahead = optional_int_field "ahead" fields in
  let* behind = optional_int_field "behind" fields in
  Ok
    { checkout
    ; origin
    ; branch
    ; head
    ; dirty
    ; target_ref
    ; upstream_head
    ; target_ref_last_observed_at_unix
    ; ahead
    ; behind
    }

let parse_probe_json ~root raw_json =
  match Yojson.Safe.from_string raw_json with
  | exception Yojson.Json_error msg ->
    Error (Printf.sprintf "invalid probe json: %s" msg)
  | json ->
    let* fields = object_fields "probe output" json in
    let* checkouts_json =
      match field "checkouts" fields with
      | `List rows -> Ok rows
      | other -> wrong_shape "checkouts" "a list" other
    in
    let* limit = parse_limit (field "limit" fields) in
    let* inspections =
      List.fold_left
        (fun acc (index, row) ->
           let* acc = acc in
           let* inspection =
             parse_checkout ~root row
             |> Result.map_error (fun detail ->
                    Printf.sprintf "checkouts[%d]: %s" index detail)
           in
           Ok (inspection :: acc))
        (Ok [])
        (List.mapi (fun index row -> index, row) checkouts_json)
      |> Result.map List.rev
    in
    let found = List.map (fun (i : inspected_checkout) -> i.checkout) inspections in
    let discovery : Keeper_playground_checkouts.discovery =
      match limit with
      | Some l -> Keeper_playground_checkouts.Partial { found; limit = l }
      | None -> Keeper_playground_checkouts.Complete found
    in
    Ok (Ok discovery, inspections)

let parse_layout_json ~root raw_json =
  match Yojson.Safe.from_string raw_json with
  | exception Yojson.Json_error detail -> Error ("invalid probe json: " ^ detail)
  | json ->
    let* fields = object_fields "probe output" json in
    let* entries =
      match field "entries" fields with
      | `List entries ->
        List.fold_left (fun result entry ->
          let* entries = result in
          match entry with
          | `String entry -> Ok (entry :: entries)
          | other -> wrong_shape "entries[]" "a string" other)
          (Ok []) entries |> Result.map List.rev
      | other -> wrong_shape "entries" "a list" other
    in
    let* checkouts =
      match field "checkouts" fields with
      | `List rows ->
        List.fold_left (fun result row ->
          let* checkouts = result in
          let* checkout = parse_checkout_path ~root row in
          Ok (checkout :: checkouts)) (Ok []) rows |> Result.map List.rev
      | other -> wrong_shape "checkouts" "a list" other
    in
    (* Missing [limit] must not be read as a complete scan. *)
    let* limit_json =
      match List.assoc_opt "limit" fields with
      | Some limit -> Ok limit
      | None -> Error "probe output is missing limit"
    in
    let* limit = parse_limit limit_json in
    let discovery = match limit with
      | None -> Keeper_playground_checkouts.Complete checkouts
      | Some limit -> Keeper_playground_checkouts.Partial { found = checkouts; limit }
    in
    Ok { entries; discovery }

let catalog_to_json_arg catalog =
  let repos =
    match catalog with
    | Ok (c : Repo_manager_types.repository list) -> c
    | Error _ -> []
  in
  let json_repos =
    List.map
      (fun (r : Repo_manager_types.repository) ->
         `Assoc
           [ "id", `String r.id
           ; "url", `String r.url
           ; "default_branch", `String r.default_branch
           ])
      repos
  in
  Yojson.Safe.to_string (`List json_repos)

type budgets =
  { guest_state_sec : float
  ; payload_sec : float
  ; checkout_sec : float
  ; workers : int
  }

let budgets ~timeout_sec =
  { guest_state_sec = guest_state_timeout_sec
  ; payload_sec = timeout_sec
  ; checkout_sec = checkout_inspection_sec
  ; workers = inspection_workers
  }
;;

(* Zero-based index of the mode argument (["inspect"] / ["layout"]) inside the
   [python3 -c <probe_script> ...] [argv] built in [probe_argv] below. Inside
   [probe_script] this corresponds to [sys.argv[5]]. *)
let probe_mode_argv_index = 7

type probe_mode = Inspect | Layout

let probe_argv ~catalog_arg ~mode ~(budgets : budgets) =
  [ "python3"
  ; "-c"
  ; probe_script
  ; catalog_arg
  ; string_of_int Keeper_playground_checkouts.max_reported_checkouts
  ; string_of_int Keeper_playground_checkouts.max_scanned_entries
  ; string_of_int target_ref_stale_after_s
  ; (match mode with Inspect -> "inspect" | Layout -> "layout")
  ; Printf.sprintf "%g" budgets.checkout_sec
  ; string_of_int budgets.workers
  ]
;;

module For_testing = struct
  let probe_script = probe_script
  let probe_mode_argv_index = probe_mode_argv_index
  let budgets = budgets
end

let run_probe ?read_authority ~timeout_sec ~(config : Workspace.config)
    ~(meta : keeper_meta) ~catalog ~mode ~parse ()
  =
  let budgets = budgets ~timeout_sec in
  let root =
    match (match read_authority with None -> Keeper_sandbox_remote_lane.workspace_root ~config ~meta
      | Some authority -> Ok (Keeper_sandbox_remote_lane.read_authority_workspace_root authority)) with
    | Ok r -> r
    | Error _ -> "."
  in
  let requires_boot_marker = match mode with Inspect -> true | Layout -> false in
  if requires_boot_marker && not (Keeper_sandbox_remote_lane.is_guest_booted ~config ~meta ())
  then
    (* A microvm keeper that has not yet booted its guest in this process
       lifetime has no playground to inspect — absence, not a failure. *)
    Error (Keeper_playground_checkouts.Root_missing { root })
  else
    let execute endpoint =
      let root = Keeper_sandbox_remote.workspace_root endpoint in
      let runner = Keeper_sandbox_remote.runner ~timeout_sec:budgets.payload_sec endpoint in
      let catalog_arg = catalog_to_json_arg catalog in
      (* The probe takes both budgets from here so the endpoint walk and the
         host walk in [Keeper_playground_checkouts] stop at the same numbers. *)
      let argv = probe_argv ~catalog_arg ~mode ~budgets in
      (* Matched rather than collapsed with [status_tuple]: that helper turns
         a transport failure into a non-zero status (the timeout status or
         [WEXITED 1]), and the non-zero-exit arm below reports
         [Root_unreadable] -- a claim about the root. A payload that exceeded
         the remote timeout never read the root at all, and its own [.mli]
         says not to collapse where a non-zero exit carries a distinct
         meaning. *)
      let outcome =
        runner
          ~on_stdout_chunk:None
          ~on_stderr_chunk:None
          ~stdin_content:None
          ~argv
          ~env:[||]
          ~cwd:(Some root)
      in
      Ok (root, outcome)
    in
    let dispatched = match read_authority with
      | None ->
        Result.bind
          (Keeper_sandbox_remote_lane.attached_guest_endpoint
             ~timeout_sec:budgets.guest_state_sec ~config ~meta ())
          execute
      | Some authority ->
        Keeper_sandbox_remote_lane.with_read_authority_endpoint
          ~timeout_sec:budgets.guest_state_sec authority ~config ~meta execute in
    let guest_absence () =
      Keeper_turn_sandbox_runtime.microvm_guest_absence_reason
        ~timeout_sec:budgets.guest_state_sec ~config ~meta ()
    in
    match dispatched with
    | Error err ->
      (match guest_absence () with
       | Some _ -> Error (Keeper_playground_checkouts.Root_missing { root })
       | None ->
         Error (Keeper_playground_checkouts.Root_unreadable { root; detail = err }))
    | Ok (root, outcome) ->
      match outcome with
      | Masc_exec.Sandbox_target.Transport_failed { reason; _ } -> (
        (* A guest that has gone away is absence, the same answer the exit
           arms give it, and the booted flag has to be dropped either way. *)
        match guest_absence () with
        | Some _ ->
          Error (Keeper_playground_checkouts.Root_missing { root })
        | None ->
          Error (Keeper_playground_checkouts.Root_probe_unreachable { root; reason }))
      | Masc_exec.Sandbox_target.Ran { status; stdout; stderr; _ } ->
      match status with
      | Unix.WEXITED 0 ->
        (match parse ~root stdout with
         | Ok result -> Ok result
         | Error err ->
           Error (Keeper_playground_checkouts.Root_unreadable { root; detail = err }))
      | Unix.WEXITED code ->
        (match guest_absence () with
         | Some _ ->
           Error (Keeper_playground_checkouts.Root_missing { root })
         | None ->
           let detail =
             Printf.sprintf "remote probe exited %d: %s" code (Exec_policy.truncate_for_log stderr)
           in
           Error (Keeper_playground_checkouts.Root_unreadable { root; detail }))
      | Unix.WSIGNALED signal ->
        (match guest_absence () with
         | Some _ ->
           Error (Keeper_playground_checkouts.Root_missing { root })
         | None ->
           let detail =
             Printf.sprintf "remote probe signaled %d: %s" signal (Exec_policy.truncate_for_log stderr)
           in
           Error (Keeper_playground_checkouts.Root_unreadable { root; detail }))
      | Unix.WSTOPPED signal ->
        let detail = Printf.sprintf "remote probe stopped %d" signal in
        Error (Keeper_playground_checkouts.Root_unreadable { root; detail })

let discover_and_inspect ~timeout_sec ~config ~meta ~catalog () =
  run_probe ~timeout_sec ~config ~meta ~catalog ~mode:Inspect
    ~parse:parse_probe_json ()

let discover_layout ?read_authority ~timeout_sec ~config ~meta () =
  run_probe ?read_authority ~timeout_sec ~config ~meta ~catalog:(Ok []) ~mode:Layout
    ~parse:parse_layout_json ()
