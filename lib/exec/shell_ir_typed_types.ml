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
  | Generic :
      Shell_ir.simple
      -> (Shell_ir.simple, string, [ `Privileged ], [ `Host ]) command
