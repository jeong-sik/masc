type risk_class =
  [ `Safe
  | `Audited
  | `Privileged
  ]

type kind =
  [ `Git
  | `Docker
  | `Curl
  | `Ssh
  | `Other_audited
  | `Safe_bin
  | `Privileged_bin
  ]

(** Closed variant of every binary the exec gate knows about.

    Each constructor maps to exactly one string name via {!name_of_known}.
    Adding a new binary requires adding a constructor here AND updating
    {!name_of_known} — the compiler enforces completeness. *)
type known =
  (* Safe *)
  | Ls
  | Cat
  | Pwd
  | Echo
  | Head
  | Tail
  | Grep
  | Rg
  | Find
  | Which
  | Test
  | Basename
  | Dirname
  | Stat
  | Du
  | Df
  | Sort
  | Uniq
  | Wc
  | Cut
  | Tr
  | Date
  | Env
  | Printenv
  | Hostname
  | Whoami
  | Uname
  | Ps
  | Tty
  (* Audited *)
  | Git
  | Docker
  | Curl
  | Wget
  | Ssh
  | Scp
  | Tar
  | Rsync
  | Make
  | Cmake
  | Npm
  | Yarn
  | Pnpm
  | Pip
  | Opam
  | Cargo
  | Gh
  | Glab
  | Terminal_notifier
  | Osascript
  | Play
  | Rec
  | Ffplay
  | Mpg123
  | Open
  | Claude
  | Gemini
  | Codex
  (* Privileged *)
  | Sudo
  | Su
  | Chmod
  | Chown
  | Rm
  | Dd
  | Mkfs

let name_of_known : known -> string = function
  | Ls -> "ls"
  | Cat -> "cat"
  | Pwd -> "pwd"
  | Echo -> "echo"
  | Head -> "head"
  | Tail -> "tail"
  | Grep -> "grep"
  | Rg -> "rg"
  | Find -> "find"
  | Which -> "which"
  | Test -> "test"
  | Basename -> "basename"
  | Dirname -> "dirname"
  | Stat -> "stat"
  | Du -> "du"
  | Df -> "df"
  | Sort -> "sort"
  | Uniq -> "uniq"
  | Wc -> "wc"
  | Cut -> "cut"
  | Tr -> "tr"
  | Date -> "date"
  | Env -> "env"
  | Printenv -> "printenv"
  | Hostname -> "hostname"
  | Whoami -> "whoami"
  | Uname -> "uname"
  | Ps -> "ps"
  | Tty -> "tty"
  | Git -> "git"
  | Docker -> "docker"
  | Curl -> "curl"
  | Wget -> "wget"
  | Ssh -> "ssh"
  | Scp -> "scp"
  | Tar -> "tar"
  | Rsync -> "rsync"
  | Make -> "make"
  | Cmake -> "cmake"
  | Npm -> "npm"
  | Yarn -> "yarn"
  | Pnpm -> "pnpm"
  | Pip -> "pip"
  | Opam -> "opam"
  | Cargo -> "cargo"
  | Gh -> "gh"
  | Glab -> "glab"
  | Terminal_notifier -> "terminal-notifier"
  | Osascript -> "osascript"
  | Play -> "play"
  | Rec -> "rec"
  | Ffplay -> "ffplay"
  | Mpg123 -> "mpg123"
  | Open -> "open"
  | Claude -> "claude"
  | Gemini -> "gemini"
  | Codex -> "codex"
  | Sudo -> "sudo"
  | Su -> "su"
  | Chmod -> "chmod"
  | Chown -> "chown"
  | Rm -> "rm"
  | Dd -> "dd"
  | Mkfs -> "mkfs"
;;

let risk_of_known : known -> risk_class = function
  | Ls
  | Cat
  | Pwd
  | Echo
  | Head
  | Tail
  | Grep
  | Rg
  | Find
  | Which
  | Test
  | Basename
  | Dirname
  | Stat
  | Du
  | Df
  | Sort
  | Uniq
  | Wc
  | Cut
  | Tr
  | Date
  | Env
  | Printenv
  | Hostname
  | Whoami
  | Uname
  | Ps
  | Tty -> `Safe
  | Git
  | Docker
  | Curl
  | Wget
  | Ssh
  | Scp
  | Tar
  | Rsync
  | Make
  | Cmake
  | Npm
  | Yarn
  | Pnpm
  | Pip
  | Opam
  | Cargo
  | Gh
  | Glab
  | Terminal_notifier
  | Osascript
  | Play
  | Rec
  | Ffplay
  | Mpg123
  | Open
  | Claude
  | Gemini
  | Codex -> `Audited
  | Sudo | Su | Chmod | Chown | Rm | Dd | Mkfs -> `Privileged
;;

let kind_of_known : known -> kind = function
  | Ls
  | Cat
  | Pwd
  | Echo
  | Head
  | Tail
  | Grep
  | Rg
  | Find
  | Which
  | Test
  | Basename
  | Dirname
  | Stat
  | Du
  | Df
  | Sort
  | Uniq
  | Wc
  | Cut
  | Tr
  | Date
  | Env
  | Printenv
  | Hostname
  | Whoami
  | Uname
  | Ps
  | Tty -> `Safe_bin
  | Git -> `Git
  | Docker -> `Docker
  | Curl -> `Curl
  | Ssh -> `Ssh
  | Wget
  | Scp
  | Tar
  | Rsync
  | Make
  | Cmake
  | Npm
  | Yarn
  | Pnpm
  | Pip
  | Opam
  | Cargo
  | Gh
  | Glab
  | Terminal_notifier
  | Osascript
  | Play
  | Rec
  | Ffplay
  | Mpg123
  | Open
  | Claude
  | Gemini
  | Codex -> `Other_audited
  | Sudo | Su | Chmod | Chown | Rm | Dd | Mkfs -> `Privileged_bin
;;

type t =
  { name : string
  ; risk : risk_class
  ; kind : kind
  ; known : known option
  }

type unknown = [ `Unknown of string ]

(** Reverse lookup: string name → [known] variant.

    Uses an exhaustive match so that adding a new constructor to [known]
    triggers a compile error here — the developer cannot forget to
    register the string mapping. *)
let known_of_string : string -> known option = function
  | "ls" -> Some Ls
  | "cat" -> Some Cat
  | "pwd" -> Some Pwd
  | "echo" -> Some Echo
  | "head" -> Some Head
  | "tail" -> Some Tail
  | "grep" -> Some Grep
  | "rg" -> Some Rg
  | "find" -> Some Find
  | "which" -> Some Which
  | "test" -> Some Test
  | "basename" -> Some Basename
  | "dirname" -> Some Dirname
  | "stat" -> Some Stat
  | "du" -> Some Du
  | "df" -> Some Df
  | "sort" -> Some Sort
  | "uniq" -> Some Uniq
  | "wc" -> Some Wc
  | "cut" -> Some Cut
  | "tr" -> Some Tr
  | "date" -> Some Date
  | "env" -> Some Env
  | "printenv" -> Some Printenv
  | "hostname" -> Some Hostname
  | "whoami" -> Some Whoami
  | "uname" -> Some Uname
  | "ps" -> Some Ps
  | "tty" -> Some Tty
  | "git" -> Some Git
  | "docker" -> Some Docker
  | "curl" -> Some Curl
  | "wget" -> Some Wget
  | "ssh" -> Some Ssh
  | "scp" -> Some Scp
  | "tar" -> Some Tar
  | "rsync" -> Some Rsync
  | "make" -> Some Make
  | "cmake" -> Some Cmake
  | "npm" -> Some Npm
  | "yarn" -> Some Yarn
  | "pnpm" -> Some Pnpm
  | "pip" -> Some Pip
  | "opam" -> Some Opam
  | "cargo" -> Some Cargo
  | "gh" -> Some Gh
  | "glab" -> Some Glab
  | "terminal-notifier" -> Some Terminal_notifier
  | "osascript" -> Some Osascript
  | "play" -> Some Play
  | "rec" -> Some Rec
  | "ffplay" -> Some Ffplay
  | "mpg123" -> Some Mpg123
  | "open" -> Some Open
  | "claude" -> Some Claude
  | "gemini" -> Some Gemini
  | "codex" -> Some Codex
  | "sudo" -> Some Sudo
  | "su" -> Some Su
  | "chmod" -> Some Chmod
  | "chown" -> Some Chown
  | "rm" -> Some Rm
  | "dd" -> Some Dd
  | "mkfs" -> Some Mkfs
  | _ -> None
;;

let of_string raw =
  if raw = ""
  then Error (`Unknown raw)
  else (
    let name = Filename.basename raw in
    match known_of_string name with
    | Some k ->
      Ok { name; risk = risk_of_known k; kind = kind_of_known k; known = Some k }
    | None ->
      (* Unknown binary -> Privileged per RFC v5 fail-closed rule. *)
      Ok { name; risk = `Privileged; kind = `Privileged_bin; known = None })
;;

let risk_class t = t.risk
let kind t = t.kind
let to_string t = t.name

(** Construct a [t] directly from a [known] variant — no string parsing,
    no risk of [Error]. *)
let of_known k =
  { name = name_of_known k
  ; risk = risk_of_known k
  ; kind = kind_of_known k
  ; known = Some k
  }
;;

(** Returns [Some k] when the binary is in the known registry, [None]
    for unknown binaries classified as Privileged by default. *)
let known t = t.known

let pp fmt t =
  let tag =
    match t.risk with
    | `Safe -> "safe"
    | `Audited -> "audited"
    | `Privileged -> "privileged"
  in
  Format.fprintf fmt "%s:%s" tag t.name
;;

let equal a b = String.equal a.name b.name
let to_yojson t = `String t.name
