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
      ; dest_dir : string option
        (** Optional local directory to clone into. When [None], git uses the
            basename of [repo]. *)
      }
      -> (unit, string, [ `Audited ], [ `Host | `Docker ]) command
  | Curl :
      { url : string
      ; method_ : [ `GET | `POST | `PUT | `DELETE ]
      ; headers : (string * string) list option
      ; body : string option
      ; output_file : string option
      ; follow_redirects : bool
      ; insecure : bool
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
      ; maxdepth : int option
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
      ; files_with_matches : bool
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
  | Git_stash :
      { action : [ `Push | `Pop | `Drop | `List | `Show ]
      ; message : string option
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Git_rebase :
      { interactive : bool
      ; onto : string option
      ; branch : string option
      ; continue_ : bool
      ; abort : bool
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Git_merge :
      { no_ff : bool
      ; squash : bool
      ; branch : string
      ; abort : bool
      ; continue_ : bool
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Git_branch :
      { delete : string option
      ; list_all : bool
      ; rename : string option
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Git_checkout :
      { new_branch : bool
      ; branch : string
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Git_fetch :
      { remote : string option
      ; branch : string option
      ; prune : bool
      ; all : bool
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Git_show :
      { commit : string
      ; stat : bool
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Git_reset :
      { mode : [ `Soft | `Mixed | `Hard ]
      ; target : string option
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Git_blame :
      { file : string
      ; range : string option
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Git_add :
      { paths : string list
      ; force : bool
      ; update : bool
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
      ; skip_fields : int option
      ; skip_chars : int option
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
      ; continue_ : bool
      ; no_check_certificate : bool
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Ssh :
      { host : string
      ; user : string option
      ; command : string option
      ; port : int option
      ; identity_file : string option
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
      ; directory : string option
      ; makefile : string option
      ; dry_run : bool
      ; keep_going : bool
      ; silent : bool
      ; always_make : bool
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Diff :
      { file1 : string
      ; file2 : string
      ; unified : bool
      ; brief : bool
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Sed :
      { expression : string
      ; file : string
      ; in_place : bool
      ; extended_regex : bool
      ; suppress_output : bool
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Rsync :
      { source : string
      ; dest : string
      ; archive : bool
      ; delete : bool
      ; dry_run : bool
      ; compress : bool
      ; flags : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Node :
      { script : string
      ; args : string list
      ; inline : string option
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Python :
      { script : string
      ; args : string list
      ; inline : string option
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Python3 :
      { script : string
      ; args : string list
      ; inline : string option
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
      ; save_dev : bool
      ; global : bool
      ; force : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Cargo :
      { subcommand : string
      ; release : bool
      ; verbose : bool
      ; features : string option
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Go :
      { subcommand : string
      ; verbose : bool
      ; race : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Gh :
      { subcommand : string
      ; action : string option
      ; draft : bool
      ; squash : bool
      ; delete_branch : bool
      ; body : string option
      ; title : string option
      ; search : string option
      ; state : string option
      ; rest : string list
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
      ; rm : bool
      ; privileged : bool
      ; detach : bool
      ; name : string option
      ; network : string option
      ; volumes : string list
      ; publish : string list
      ; env_vars : string list
      ; workdir : string option
      ; platform : string option
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Docker ]) command
  | Opam :
      { subcommand : string
      ; yes : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Npx :
      { subcommand : string
      ; yes : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Yarn :
      { subcommand : string
      ; dev : bool
      ; global : bool
      ; production : bool
      ; frozen_lockfile : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Pnpm :
      { subcommand : string
      ; save_dev : bool
      ; global : bool
      ; force : bool
      ; production : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Uv :
      { subcommand : string
      ; no_cache : bool
      ; system : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Glab :
      { subcommand : string
      ; yes : bool
      ; force : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Pytest :
      { subcommand : string
      ; verbose : bool
      ; exitfirst : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Terminal_notifier :
      { title : string
      ; message : string
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Ruff :
      { subcommand : string
      ; fix : bool
      ; show_source : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Pyright :
      { subcommand : string
      ; strict : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Tsc :
      { subcommand : string
      ; no_emit : bool
      ; watch : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Ocamlfind :
      { subcommand : string
      ; args : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Rustc :
      { subcommand : string
      ; optimize : bool
      ; test : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Gofmt :
      { subcommand : string
      ; write : bool
      ; list_files : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Gradle :
      { subcommand : string
      ; no_daemon : bool
      ; parallel : bool
      ; rest : string list
      }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | Ninja :
      { subcommand : string
      ; jobs : int option
      ; rest : string list
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
      ; offline : bool
      ; batch_mode : bool
      ; quiet : bool
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
  | Cp :
      { source : string
      ; dest : string
      ; recursive : bool
      ; force : bool
      ; preserve : bool
      }
      -> (unit, unit, [ `Safe ], [ `Host ]) command
  | Mv :
      { source : string
      ; dest : string
      ; force : bool
      ; no_clobber : bool
      }
      -> (unit, unit, [ `Safe ], [ `Host ]) command
  | Ln :
      { target : string
      ; link_name : string
      ; symbolic : bool
      ; force : bool
      }
      -> (unit, unit, [ `Safe ], [ `Host ]) command
  | Touch :
      { files : string list
      ; no_create : bool
      ; time : [ `Access | `Modify ] option
      }
      -> (unit, unit, [ `Safe ], [ `Host ]) command
  | Tee :
      { files : string list
      ; append : bool
      }
      -> (unit, unit, [ `Safe ], [ `Host ]) command
  | Awk :
      { program : string
      ; files : string list
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Xargs :
      { command : string
      ; args : string list
      ; null_terminated : bool
      ; max_args : int option
      }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Generic :
      Shell_ir.simple
      -> (Shell_ir.simple, string, [ `Privileged ], [ `Host ]) command

(** [is_eq_form_flag arg flags] returns [true] if [arg] is an eq-form
    value flag (e.g., "--flag=VALUE") whose prefix before '=' is in [flags].
    Handles both --flag=VALUE and -flag=VALUE forms. *)
let is_eq_form_flag (arg : string) (flags : string list) : bool =
  String.length arg > 2
  && arg.[0] = '-'
  && (match String.index_opt arg '=' with
      | Some i -> List.mem (String.sub arg 0 i) flags
      | None -> false)

(** [eq_form_flag_value arg flags] returns [Some value] if [arg] is an
    eq-form value flag whose prefix before '=' is in [flags], extracting
    the portion after '='. Returns [None] if [arg] is not a matching
    eq-form flag. Handles both --flag=VALUE and -flag=VALUE forms. *)
let eq_form_flag_value (arg : string) (flags : string list) : string option =
  if String.length arg > 2 && arg.[0] = '-'
  then match String.index_opt arg '=' with
    | Some i when List.mem (String.sub arg 0 i) flags ->
      Some (String.sub arg (i + 1) (String.length arg - (i + 1)))
    | _ -> None
  else None
