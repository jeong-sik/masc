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

catalog_raw = sys.argv[1] if len(sys.argv) > 1 else '[]'
try:
    catalog = json.loads(catalog_raw)
except Exception:
    catalog = []

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
        except Exception:
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
max_scanned = 8192
max_checkouts = 12
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
    while queue and len(checkouts) < max_checkouts and scanned < max_scanned:
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
        except Exception:
            continue
        for e in entries:
            if e in ('.', '..', '.git'): continue
            c_full = os.path.join(full, e)
            if os.path.isdir(c_full) and not os.path.islink(c_full):
                c_rel = os.path.join(rel, e) if rel else e
                queue.append(c_rel)

if len(checkouts) >= max_checkouts:
    limit = {'kind': 'checkout_budget_exhausted', 'budget': max_checkouts}
elif scanned >= max_scanned:
    limit = {'kind': 'entry_budget_exhausted', 'scanned': scanned, 'budget': max_scanned}

checkouts.sort(key=lambda c: c['relative_path'])

result = {
    'checkouts': checkouts,
    'scanned': scanned,
    'limit': limit
}
print(json.dumps(result))
|}

let string_member_opt key json =
  match Yojson.Safe.Util.member key json with
  | `String s -> Some s
  | _ -> None

let int_member_opt key json =
  match Yojson.Safe.Util.member key json with
  | `Int i -> Some i
  | _ -> None

let bool_member_opt key json =
  match Yojson.Safe.Util.member key json with
  | `Bool b -> Some b
  | _ -> None

let parse_limit = function
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "entry_budget_exhausted") ->
       let scanned =
         match List.assoc_opt "scanned" fields with
         | Some (`Int s) -> s
         | _ -> 0
       in
       let budget =
         match List.assoc_opt "budget" fields with
         | Some (`Int b) -> b
         | _ -> 8_192
       in
       Some
         (Keeper_playground_checkouts.Entry_budget_exhausted
            { scanned; budget })
     | Some (`String "checkout_budget_exhausted") ->
       let budget =
         match List.assoc_opt "budget" fields with
         | Some (`Int b) -> b
         | _ -> Keeper_playground_checkouts.max_reported_checkouts
       in
       Some (Keeper_playground_checkouts.Checkout_budget_exhausted { budget })
     | _ -> None)
  | _ -> None

let parse_checkout ~root json =
  let open Yojson.Safe.Util in
  let relative_path = member "relative_path" json |> to_string in
  let name = member "name" json |> to_string in
  let git_link_str = member "git_link" json |> to_string in
  let git_link =
    if String.equal git_link_str "directory"
    then Keeper_playground_checkouts.Git_directory
    else Keeper_playground_checkouts.Git_pointer_file
  in
  let absolute_path =
    if String.equal relative_path "."
    then root
    else Filename.concat root relative_path
  in
  let checkout : Keeper_playground_checkouts.checkout =
    { relative_path; absolute_path; name; git_link }
  in
  let origin_url = string_member_opt "origin" json in
  let branch =
    match string_member_opt "branch" json with
    | Some b -> Ok b
    | None -> Error "branch unavailable"
  in
  let head =
    match string_member_opt "head" json with
    | Some h -> Ok h
    | None -> Error "head unavailable"
  in
  let dirty =
    match bool_member_opt "dirty" json, int_member_opt "changed_files" json with
    | Some d, Some c -> Ok (d, c)
    | Some d, None -> Ok (d, if d then 1 else 0)
    | None, _ -> Error "status unavailable"
  in
  let target_ref = string_member_opt "target_ref" json in
  let upstream_head = string_member_opt "upstream_head" json in
  let ahead = int_member_opt "ahead" json in
  let behind = int_member_opt "behind" json in
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
    let open Yojson.Safe.Util in
    let checkouts_json =
      match member "checkouts" json with
      | `List l -> l
      | _ -> []
    in
    let limit = parse_limit (member "limit" json) in
    let inspections = List.map (parse_checkout ~root) checkouts_json in
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
  match Keeper_sandbox_remote_lane.attached_guest_endpoint ~config ~meta () with
  | Error err ->
    let root =
      match Keeper_sandbox_remote_lane.remote_root ~config ~meta with
      | Ok r -> r
      | Error _ -> "."
    in
    Error (Keeper_playground_checkouts.Root_unreadable { root; detail = err })
  | Ok endpoint ->
    let root = Keeper_sandbox_remote.remote_keeper_root endpoint in
    let runner = Keeper_sandbox_remote.runner ~timeout_sec endpoint in
    let catalog_arg = catalog_to_json_arg catalog in
    let argv = [ "python3"; "-c"; probe_script; catalog_arg ] in
    let status, stdout, stderr =
      runner
        ~on_stdout_chunk:None
        ~on_stderr_chunk:None
        ~stdin_content:None
        ~argv
        ~env:[||]
        ~cwd:(Some root)
    in
    match status with
    | Unix.WEXITED 0 ->
      (match parse_probe_json ~root stdout with
       | Ok result -> Ok result
       | Error err ->
         Error (Keeper_playground_checkouts.Root_unreadable { root; detail = err }))
    | Unix.WEXITED code ->
      let detail =
        Printf.sprintf "remote probe exited %d: %s" code (Exec_policy.truncate_for_log stderr)
      in
      Error (Keeper_playground_checkouts.Root_unreadable { root; detail })
    | Unix.WSIGNALED signal ->
      let detail =
        Printf.sprintf "remote probe signaled %d: %s" signal (Exec_policy.truncate_for_log stderr)
      in
      Error (Keeper_playground_checkouts.Root_unreadable { root; detail })
    | Unix.WSTOPPED signal ->
      let detail = Printf.sprintf "remote probe stopped %d" signal in
      Error (Keeper_playground_checkouts.Root_unreadable { root; detail })
