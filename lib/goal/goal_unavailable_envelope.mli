(** Goal_unavailable_envelope — the one wire projection of a goal store this
    build cannot read (RFC-0444 §2.3 rows 1–3).

    The envelope is
    [{ ok:false, error_code:"goal_store_unavailable", reason, field, file,
       mirror:{status, goal_count}, reset_step }] where [reason],
    [mirror.status] and [reset_step] are constructor names in lowercase snake
    case ({!Goal_store_unavailable.reason_name} and siblings), [field] is the
    refused member for [Schema_rejected] and [null] otherwise, and
    [mirror.goal_count] is the mirror's row count for [Mirror_decodes] and
    [null] otherwise. No response built from it carries a [goals] member. *)

val error_code : Tool_args.error_code
(** {!Tool_args.Unavailable}; its wire token is [goal_store_unavailable]. *)

val to_yojson : Goal_store.unavailable -> Yojson.Safe.t
(** The envelope as a JSON object. HTTP routes send it as the body. *)

val tool_result : tool_name:string -> start_time:float -> Goal_store.unavailable -> Tool_result.result
(** The envelope as a failed tool result: {!to_yojson} is both the structured
    [data] and, serialized, the message; the failure class is
    {!Tool_result.Dependency_unavailable}. *)
