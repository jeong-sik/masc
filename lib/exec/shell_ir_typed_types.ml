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
  | Generic :
      Shell_ir.simple
      -> (Shell_ir.simple, string, [ `Privileged ], [ `Host ]) command
