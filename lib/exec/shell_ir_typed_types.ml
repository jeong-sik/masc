(** Shell_ir_typed_types — GADT type definitions extracted from
    Shell_ir_typed to break the circular dependency between
    Shell_ir_typed and Shell_ir_typed_walkers_gen.

    Both modules reference these types through this shared module
    so that Shell_ir_typed can delegate to Shell_ir_typed_walkers_gen
    without creating a compilation-unit cycle. *)

type risk =
  [ `Safe
  | `Audited
  | `Privileged
  ]

type sandbox =
  [ `Host
  | `Docker
  ]

type wrapped = W : ('i, 'o, 'r, 's) command -> wrapped

and (_, _, _, _) command =
  | Ls :
      { path : string option
      ; flags : [ `Long | `All | `Human ] list
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Cat : { path : string } -> (unit, string, [ `Safe ], [ `Host ]) command
  | Rg :
      { pattern : string
      ; path : string option
      ; case_sensitive : bool
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Git_status : { short : bool } -> (unit, string, [ `Audited ], [ `Host ]) command
  | Git_clone :
      { repo : string
      ; branch : string option
      ; depth : int option
        (** [None] = unlimited (no [--depth] flag); [Some n] = shallow clone. *)
      }
      -> (unit, string, [ `Audited ], [ `Host | `Docker ]) command
  | Curl :
      { url : string
      ; method_ : [ `GET | `POST | `PUT | `DELETE ]
      ; headers : (string * string) list option
      ; body : string option
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Rm :
      { paths : string list
      ; recursive : bool
      ; force : bool
      }
      -> (unit, unit, [ `Privileged ], [ `Host ]) command
  | Sudo :
      { target_argv : string list
        (** Tokenized argv to be passed to [sudo].  Stored as a list
            (not a space-joined string) so that arguments containing
            spaces — e.g. [sudo sh -c "echo hi"] — round-trip cleanly
            through [to_simple] and [Capability_check_typed.of_command]
            without being re-split on whitespace. *)
      }
      -> (unit, string, [ `Privileged ], [ `Host ]) command
  | Find :
      { path : string
      ; name : string option
      ; type_ : [ `File | `Dir ] option
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Head :
      { path : string
      ; lines : int
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Tail :
      { path : string
      ; lines : int
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Grep :
      { pattern : string
      ; path : string option
      ; recursive : bool
      ; case_sensitive : bool
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Mkdir :
      { path : string
      ; parents : bool
      }
      -> (unit, unit, [ `Safe ], [ `Host ]) command
  | Wc :
      { path : string
      ; mode : [ `Lines | `Words | `Chars ] option
        (** [None] = all three counts (no flag); [Some m] = specific mode. *)
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Git_diff :
      { stat : bool
      ; cached : bool
      ; paths : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Git_log :
      { oneline : bool
      ; max_count : int option
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Git_commit :
      { message : string
      ; amend : bool
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Git_push :
      { force : bool
      ; force_with_lease : bool
      ; set_upstream : bool
      ; remote : string option
      ; branch : string option
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Git_pull :
      { rebase : bool
      ; remote : string option
      ; branch : string option
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Pwd : unit -> (unit, string, [ `Safe ], [ `Host ]) command
  | Echo :
      { args : string list }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Which :
      { names : string list }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Sort :
      { reverse : bool
      ; numeric : bool
      ; unique : bool
      ; key : int option
      ; file : string option
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Cut :
      { delimiter : string option
      ; fields : string
      ; file : string option
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Tr :
      { set1 : string
      ; set2 : string option
      ; delete : bool
      ; squeeze : bool
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Date :
      { format : string option
      ; utc : bool
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Env : unit -> (unit, string, [ `Safe ], [ `Host ]) command
  | Printenv :
      { name : string option }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Uniq :
      { count : bool
      ; duplicates : bool
      ; unique : bool
      ; file : string option
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Basename :
      { path : string
      ; suffix : string option
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Dirname : { path : string } -> (unit, string, [ `Safe ], [ `Host ]) command
  | Test :
      { expression : string list }
      -> (unit, unit, [ `Safe ], [ `Host ]) command
  | Stat :
      { format : string option
      ; path : string
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Hostname : { short : bool } -> (unit, string, [ `Safe ], [ `Host ]) command
  | Whoami : unit -> (unit, string, [ `Safe ], [ `Host ]) command
  | Du :
      { path : string option
      ; human_readable : bool
      ; summary : bool
      ; max_depth : int option
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Df :
      { path : string option
      ; human_readable : bool
      ; filesystem_type : string option
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | File :
      { path : string
      ; mime : bool
      ; brief : bool
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Printf :
      { format : string
      ; args : string list
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Uname :
      { all : bool
      ; kernel_name : bool
      ; release : bool
      ; machine : bool
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Ps :
      { all : bool
      ; full : bool
      ; user : string option
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Tty : unit -> (unit, string, [ `Safe ], [ `Host ]) command
  | Wget :
      { url : string
      ; output : string option
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Ssh :
      { host : string
      ; user : string option
      ; command : string option
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Scp :
      { source : string
      ; dest : string
      ; recursive : bool
      ; port : int option
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Tar :
      { action : [ `Create | `Extract | `List ]
      ; archive : string
      ; paths : string list
      ; compression : [ `None | `Gzip | `Bzip2 | `Xz | `Zstd ]
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Make :
      { target : string option
      ; jobs : int option
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Diff :
      { file1 : string
      ; file2 : string
      ; unified : bool
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Sed :
      { expression : string
      ; file : string
      ; in_place : bool
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Rsync :
      { source : string
      ; dest : string
      ; flags : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Node :
      { script : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Python :
      { script : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Python3 :
      { script : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Pip :
      { subcommand : string
      ; packages : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Patch :
      { file : string option
      ; patchfile : string option
      ; strip : int
      ; reverse : bool
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Npm :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Cargo :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Go :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Gh :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Chmod :
      { mode : string
      ; path : string
      ; recursive : bool
      }
      -> (unit, string, [ `Privileged ], [ `Host ]) command
  | Chown :
      { owner : string
      ; path : string
      ; recursive : bool
      }
      -> (unit, string, [ `Privileged ], [ `Host ]) command
  | Docker :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Docker ]) command
  | Opam :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Npx :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Yarn :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Pnpm :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Uv :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Glab :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Pytest :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Terminal_notifier :
      { title : string
      ; message : string
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Ruff :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Pyright :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Tsc :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Ocamlfind :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Rustc :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Gofmt :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Gradle :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Ninja :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Java :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Javac :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Mvn :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Cmake :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Dune_local_sh :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Osascript :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Play :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Rec :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Ffplay :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Mpg123 :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Open :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Su :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Privileged ], [ `Host ]) command
  | Dd :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Privileged ], [ `Host ]) command
  | Mkfs :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Privileged ], [ `Host ]) command
  | Generic :
      Shell_ir.simple
      -> (Shell_ir.simple, string, [ `Privileged ], [ `Host ]) command
