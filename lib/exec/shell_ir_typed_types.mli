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
  | Generic :
      Shell_ir.simple
      -> (Shell_ir.simple, string, [ `Privileged ], [ `Host ]) command
