open Keeper_meta_contract

type inspected_checkout =
  { checkout : Keeper_playground_checkouts.checkout
  ; origin_url : string option
  ; branch : (string, string) result
  ; head : (string, string) result
  ; dirty : (bool * int, string) result
  ; target_ref : string option
  ; upstream_head : string option
  ; ahead : int option
  ; behind : int option
  }

let probe_script =
  {|\
import os, sys, json, subprocess

# The three arguments are built by the OCaml side; a malformed one is its
# defect and ends the probe with a traceback the caller reports.
catalog = json.loads(sys.argv[1])
checkout_budget = int(sys.argv[2])
entry_budget = int(sys.argv[3])

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
    def git(*args):
        try:
            r = subprocess.run(['git', '-C', path] + list(args), capture_output=True, text=True, timeout=5)
            return r.stdout.strip() if r.returncode == 0 else None
        except (subprocess.TimeoutExpired, OSError):
            # No git on the endpoint, or one call past its budget: that
            # field is unavailable, the rest of the row still reports.
            return None

    origin = git('config', '--get', 'remote.origin.url')
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

    return {
        'origin': origin,
        'branch': branch,
        'head': head,
        'dirty': dirty,
        'changed_files': changed_files,
        'target_ref': target_ref,
        'upstream_head': upstream_head,
        'ahead': ahead,
        'behind': behind
    }

root = '.'
checkouts = []
queue = ['']
scanned = 0
limit = None

git_root = os.path.join(root, '.git')
if os.path.exists(git_root):
    git_link = 'directory' if os.path.isdir(git_root) else 'pointer_file'
    info = inspect_git(root)
    checkouts.append({
        'relative_path': '.',
        'name': os.path.basename(os.path.abspath(root)),
        'git_link': git_link,
        **info
    })
else:
    # Past either budget by one, as the host walk is: the extra find is
    # what says the budget was exhausted rather than exactly met.
    while queue and len(checkouts) <= checkout_budget and scanned <= entry_budget:
        rel = queue.pop(0)
        full = os.path.join(root, rel) if rel else root
        scanned += 1
        git_path = os.path.join(full, '.git')
        if rel and os.path.exists(git_path):
            git_link = 'directory' if os.path.isdir(git_path) else 'pointer_file'
            info = inspect_git(full)
            checkouts.append({
                'relative_path': rel,
                'name': os.path.basename(os.path.abspath(full)),
                'git_link': git_link,
                **info
            })
            continue
        try:
            entries = sorted(os.listdir(full))
        except OSError:
            continue
        for e in entries:
            if e in ('.', '..', '.git'): continue
            c_full = os.path.join(full, e)
            if os.path.isdir(c_full) and not os.path.islink(c_full):
                c_rel = os.path.join(rel, e) if rel else e
                queue.append(c_rel)

if len(checkouts) > checkout_budget:
    limit = {'kind': 'checkout_budget_exhausted', 'budget': checkout_budget}
elif scanned > entry_budget:
    limit = {'kind': 'entry_budget_exhausted', 'scanned': scanned, 'budget': entry_budget}

checkouts.sort(key=lambda c: c['relative_path'])
checkouts = checkouts[:checkout_budget]

result = {
    'checkouts': checkouts,
    'scanned': scanned,
    'limit': limit
}
print(json.dumps(result))
|}

let ( let* ) = Result.bind

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
     | other -> Error (Printf.sprintf "limit: unknown kind %S" other))

let parse_checkout ~root json =
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
  let* origin_url = optional_string_field "origin" fields in
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
  let* ahead = optional_int_field "ahead" fields in
  let* behind = optional_int_field "behind" fields in
  Ok
    { checkout
    ; origin_url
    ; branch
    ; head
    ; dirty
    ; target_ref
    ; upstream_head
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

let discover_and_inspect
    ~timeout_sec
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~catalog
    ()
  =
  let root =
    match Keeper_sandbox_remote_lane.remote_keeper_root ~config ~meta with
    | Ok r -> r
    | Error _ -> "."
  in
  if not (Keeper_sandbox_remote_lane.is_guest_booted ~config ~meta ())
  then
    (* A microvm keeper that has not yet booted its guest in this process
       lifetime has no playground to inspect — absence, not a failure. *)
    Error (Keeper_playground_checkouts.Root_missing { root })
  else
    match Keeper_sandbox_remote_lane.attached_guest_endpoint ~config ~meta () with
    | Error err ->
      (match Keeper_turn_sandbox_runtime.microvm_guest_absence_reason ~config ~meta () with
       | Some _ -> Error (Keeper_playground_checkouts.Root_missing { root })
       | None ->
         Error (Keeper_playground_checkouts.Root_unreadable { root; detail = err }))
    | Ok endpoint ->
      let root = Keeper_sandbox_remote.remote_keeper_root endpoint in
      let runner = Keeper_sandbox_remote.runner ~timeout_sec endpoint in
      let catalog_arg = catalog_to_json_arg catalog in
      (* The probe takes both budgets from here so the endpoint walk and the
         host walk in [Keeper_playground_checkouts] stop at the same numbers. *)
      let argv =
        [ "python3"
        ; "-c"
        ; probe_script
        ; catalog_arg
        ; string_of_int Keeper_playground_checkouts.max_reported_checkouts
        ; string_of_int Keeper_playground_checkouts.max_scanned_entries
        ]
      in
      let status, stdout, stderr =
        Masc_exec.Sandbox_target.status_tuple
          (runner
             ~on_stdout_chunk:None
             ~on_stderr_chunk:None
             ~stdin_content:None
             ~argv
             ~env:[||]
             ~cwd:(Some root))
      in
      match status with
      | Unix.WEXITED 0 ->
        (match parse_probe_json ~root stdout with
         | Ok result -> Ok result
         | Error err ->
           Error (Keeper_playground_checkouts.Root_unreadable { root; detail = err }))
      | Unix.WEXITED code ->
        (match Keeper_turn_sandbox_runtime.microvm_guest_absence_reason ~config ~meta () with
         | Some _ ->
           Keeper_turn_sandbox_runtime.forget_microvm_guest_booted ~config ~meta ();
           Error (Keeper_playground_checkouts.Root_missing { root })
         | None ->
           let detail =
             Printf.sprintf "remote probe exited %d: %s" code (Exec_policy.truncate_for_log stderr)
           in
           Error (Keeper_playground_checkouts.Root_unreadable { root; detail }))
      | Unix.WSIGNALED signal ->
        (match Keeper_turn_sandbox_runtime.microvm_guest_absence_reason ~config ~meta () with
         | Some _ ->
           Keeper_turn_sandbox_runtime.forget_microvm_guest_booted ~config ~meta ();
           Error (Keeper_playground_checkouts.Root_missing { root })
         | None ->
           let detail =
             Printf.sprintf "remote probe signaled %d: %s" signal (Exec_policy.truncate_for_log stderr)
           in
           Error (Keeper_playground_checkouts.Root_unreadable { root; detail }))
      | Unix.WSTOPPED signal ->
        let detail = Printf.sprintf "remote probe stopped %d" signal in
        Error (Keeper_playground_checkouts.Root_unreadable { root; detail })
