(** Shell_ir_typed_types — GADT type exports.

    See [Shell_ir_typed_types] for documentation. *)

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
      ; depth : int
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
      { target_argv : string list }
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
      ; mode : [ `Lines | `Words | `Chars ]
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
      }
      -> (unit, unit, [ `Audited ], [ `Host ]) command
  | Tar :
      { action : [ `Create | `Extract | `List ]
      ; archive : string
      ; paths : string list
      ; gzip : bool
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
  | Generic :
      Shell_ir.simple
      -> (Shell_ir.simple, string, [ `Privileged ], [ `Host ]) command
