type status =
  | Pending
  | Cleared

type record = {
  version : int;
  keeper_name : string;
  blocker_class : string;
  summary : string;
  failure_reason : string option;
  trace_id : string option;
  generation : int option;
  committed_tools : string list;
  opened_at : string;
  updated_at : string;
  status : status;
  resolution : string option;
  evidence_refs : string list;
  cleared_at : string option;
  cleared_by : string option;
  clear_idempotency_key : string option;
}

type clear_outcome =
  | Cleared_record of record
  | Already_cleared of record
  | No_record

val record_path : Room.config -> string -> string
val record_to_yojson : record -> Yojson.Safe.t
val read : Room.config -> string -> record option
val pending_record : Room.config -> string -> record option
val is_pending : Room.config -> string -> bool
val cache_key : Room.config -> string -> string

val open_pending :
  Room.config ->
  keeper_name:string ->
  blocker_class:string ->
  summary:string ->
  failure_reason:string option ->
  trace_id:string option ->
  generation:int option ->
  committed_tools:string list ->
  record

val clear :
  Room.config ->
  keeper_name:string ->
  actor:string ->
  resolution:string ->
  evidence_refs:string list ->
  idempotency_key:string option ->
  clear_outcome
