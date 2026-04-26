(** Keeper_chat_store — JSONL-based persistence for keeper direct
    messages.

    Each keeper owns an append-only file at
    [<base_dir>/.masc/keeper_chat/<sanitized-name>.jsonl]. Lines are
    JSON objects of the form
    {v {"role":"user","content":"hello","ts":1774000000.0} v}

    @since 2.145.0 *)

(** {1 Types} *)

type chat_message =
  { role : string
  ; content : string
  ; ts : float option
  }

(** {1 I/O} *)

(** [append_pair ~base_dir ~keeper_name ~user_content ~assistant_content]
    appends two lines (user then assistant) sharing a single
    timestamp. Failures are logged but never raised except for
    {!Eio.Cancel.Cancelled}. *)
val append_pair
  :  base_dir:string
  -> keeper_name:string
  -> user_content:string
  -> assistant_content:string
  -> unit

(** [load ~base_dir ~keeper_name] returns the most recent
    [max_history] messages in chronological order. Missing files
    return [[]]. Unparseable lines are skipped. *)
val load : base_dir:string -> keeper_name:string -> chat_message list

(** {1 Serialisation} *)

(** JSON array of messages. Entries without a timestamp omit the
    [ts] field. *)
val to_json_array : chat_message list -> Yojson.Safe.t
