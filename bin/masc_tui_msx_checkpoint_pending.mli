(** Durable client intent, written before dispatch. A surviving intent is never
    evidence of success: only the server's bound receipt can retire it. *)
type binding = { operation_id : Keeper_operation_id.t; restore : bool; slot : string;
  base_path : string; masc_root : string }
val load : masc_root:string -> (binding list, string) result
(** Missing storage is empty; malformed or unreadable storage fails closed. *)
val remember : masc_root:string -> binding -> (unit, string) result
(** Flush the intent and its directory entry before returning success. *)
val forget : masc_root:string -> binding -> (unit, string) result
(** Only call after authoritative refusal or verified completion. *)
