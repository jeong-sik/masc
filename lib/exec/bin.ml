type risk_class =
  [ `Safe | `Audited | `Privileged ]

type kind =
  [ `Git
  | `Docker
  | `Curl
  | `Ssh
  | `Other_audited
  | `Safe_bin
  | `Privileged_bin
  ]

type t = {
  name : string;
  risk : risk_class;
  kind : kind;
}

type unknown = [ `Unknown of string ]

(* A0 seed table.  Expanded in A2 alongside the capability walker. *)
let safe_bins =
  [ "ls"; "cat"; "pwd"; "echo"; "head"; "tail"; "grep"; "rg"; "find";
    "which"; "test"; "basename"; "dirname"; "stat"; "du"; "df";
    "sort"; "uniq"; "wc"; "cut"; "tr"; "date"; "env"; "printenv";
    "hostname"; "whoami"; "uname"; "ps"; "tty" ]

let audited_bins =
  [ "git"; "docker"; "curl"; "wget"; "ssh"; "scp"; "tar"; "rsync";
    "make"; "cmake"; "npm"; "yarn"; "pnpm"; "pip"; "opam"; "cargo";
    "gh"; "glab"; "terminal-notifier"; "osascript"; "play"; "rec";
    "ffplay"; "mpg123"; "open"; "claude"; "gemini"; "codex" ]

let privileged_bins =
  [ "sudo"; "su"; "chmod"; "chown"; "rm"; "dd"; "mkfs" ]

(* Audited bins fan out into finer-grained kinds for typed dispatch.
   Names not explicitly enumerated below stay as [`Other_audited]; the
   wildcard is intentional, not a coverage gap. *)
let kind_of_audited = function
  | "git" -> `Git
  | "docker" -> `Docker
  | "curl" -> `Curl
  | "ssh" -> `Ssh
  | _ -> `Other_audited

let classify name : (risk_class * kind) option =
  if List.mem name safe_bins then Some (`Safe, `Safe_bin)
  else if List.mem name audited_bins then Some (`Audited, kind_of_audited name)
  else if List.mem name privileged_bins then Some (`Privileged, `Privileged_bin)
  else None

let of_string raw =
  if raw = "" then Error (`Unknown raw)
  else
    let name = Filename.basename raw in
    match classify name with
    | Some (risk, kind) -> Ok { name; risk; kind }
    | None ->
        (* Unknown binary -> Privileged per RFC v5 fail-closed rule. *)
        Ok { name; risk = `Privileged; kind = `Privileged_bin }

let risk_class t = t.risk
let kind t = t.kind
let to_string t = t.name

let pp fmt t =
  let tag = match t.risk with
    | `Safe -> "safe"
    | `Audited -> "audited"
    | `Privileged -> "privileged"
  in
  Format.fprintf fmt "%s:%s" tag t.name
