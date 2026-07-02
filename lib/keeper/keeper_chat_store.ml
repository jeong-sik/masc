(** Keeper_chat_store — JSONL-based persistence for keeper direct messages.

    Each keeper gets a file: [<base_dir>/.masc/keeper_chat/<name>.jsonl]
    Lines are append-only with timestamps.

    Line format:
    {v {"role":"user","content":"hello","ts":1774000000.0} v}

    Tool-call lines (persisted between the user and assistant lines of a
    turn) carry the executed tool name and accumulated arguments:
    {v {"role":"tool","content":"{\"path\":\"x\"}","ts":...,
        "tool_call_id":"toolu_1","tool_call_name":"Read","source":"dashboard"} v}

    Connector rows may additionally carry opaque route coordinates:
    [conversation_id] for channel/thread grouping and [external_message_id]
    for the inbound platform message. The store does not interpret these
    values.

    @since 2.145.0 *)

let sanitize_name name =
  Workspace_utils_backend_setup.sanitize_namespace_segment name

let chat_dir base_dir =
  Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) "keeper_chat"

let chat_path ~base_dir ~keeper_name =
  Filename.concat (chat_dir base_dir) (sanitize_name keeper_name ^ ".jsonl")

let persistence_surface = "keeper_chat_store"

let record_persistence_read_drop ~reason () =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_persistence_read_drops
    ~labels:[("surface", persistence_surface); ("reason", reason)]
    ()

let report_persistence_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () -> record_persistence_read_drop ~reason ())
    ~surface:persistence_surface
    ~reason
    ~path
    ~detail

let ensure_dir_once ~base_dir =
  ignore (Keeper_fs.ensure_dir (chat_dir base_dir))

type attachment = {
  id : string;
  att_type : string;
  name : string;
  size : int;
  mime_type : string;
  data : string;
}

type tool_call = {
  call_id : string;
  call_name : string;
  args : string;
}

(* RFC-0232 P1: the lane role is a closed sum parsed once at the read
   boundary; consumers match exhaustively instead of comparing role
   strings. On-disk labels are unchanged ("user"/"assistant"/"tool"). *)
module Role = struct
  type t =
    | User
    | Assistant
    | Tool

  let to_label = function
    | User -> "user"
    | Assistant -> "assistant"
    | Tool -> "tool"

  let of_label = function
    | "user" -> Some User
    | "assistant" -> Some Assistant
    | "tool" -> Some Tool
    | _ -> None

  let equal a b =
    match a, b with
    | User, User | Assistant, Assistant | Tool, Tool -> true
    | (User | Assistant | Tool), _ -> false
end

(* What an assistant line *is*, declared by the writer at append time.
   [Utterance] is something the keeper actually said; [Transport_failure]
   is the server persisting a failed request terminal ("Keeper request
   failed: ...") so the operator still sees the failure after a reload.
   Readers branch on the type: a transport failure is not a self reply —
   it does not advance the lane watermark, so the user line it failed to
   answer stays pending until the keeper's next real utterance — and it
   is never quoted back as the keeper's own words. On disk the field is
   ["kind"], absent for utterances so pre-existing rows read unchanged. *)
module Row_kind = struct
  type t =
    | Utterance
    | Transport_failure

  let to_label = function
    | Utterance -> "utterance"
    | Transport_failure -> "transport_failure"

  let of_label = function
    | "utterance" -> Some Utterance
    | "transport_failure" -> Some Transport_failure
    | _ -> None

  let equal a b =
    match a, b with
    | Utterance, Utterance | Transport_failure, Transport_failure -> true
    | (Utterance | Transport_failure), _ -> false
end

type speaker_authority =
  | Owner
  | External

let authority_label = function
  | Owner -> "owner"
  | External -> "external"

let authority_of_label = function
  | "owner" -> Some Owner
  | "external" -> Some External
  | _ -> None

type chat_block = Keeper_chat_blocks.chat_block

type audio_clip = {
  token : string;
  audio_url : string option;
  mime : string;
  duration_sec : float option;
  message_text : string;
  device_id : string option;
  expired : bool;
}

type speaker = {
  speaker_id : string option;
  speaker_name : string option;
  speaker_authority : speaker_authority;
}

type chat_message = {
  id : string;
      (* R3: producer-assigned stable message id.  Minted once at append
         by [encode_line] (the sole writer) and read back verbatim, so the
         dashboard keys off a server identity instead of synthesising an
         index-derived id at render.  Rows written before R3 carry no
         persisted id and are given a deterministic one at the read
         boundary ([legacy_message_id]); the field is therefore total. *)
  role : Role.t;
  content : string;
  ts : float option;
  attachments : attachment list option;
  tool_call_id : string option;
  tool_call_name : string option;
  source : string option;
      (* Legacy lane label.  Derived from [surface] at write since
         RFC-0232 P5 (writers no longer pass label strings); read
         verbatim from the wire so pre-P5 rows keep their label. *)
  surface : Surface_ref.t option;
      (* RFC-0232 P5: the typed surface, persisted as a structured
         [surface] field.  [None] on rows written before P5. *)
  conversation_id : string option;
  external_message_id : string option;
  speaker : speaker option;
  audio : audio_clip option;
  blocks : Keeper_chat_blocks.chat_block list option;
      (* RFC-0235 P3: rich chat blocks parsed from assistant reply text.
         Persisted server-side so the dashboard can prefer backend blocks
         over its local parser. [None] on rows written before this field
         and on non-assistant rows. *)
  mentions : Keeper_identity.Keeper_id.t list;
      (* RFC-0232 §3.3: parsed once at append from the persisted content
         (plus connector-provided explicit mentions); [] = none.  Rows
         written before P4 lack the field and read as []; the offline
         backfill tool stamps them. *)
  kind : Row_kind.t;
      (* Declared by the writer at append.  Absent field (every row
         written before this field existed) reads as [Utterance]; an
         unknown label is reported as a persistence read drop and the
         row reads as [Utterance] (the conservative arm: it renders and
         advances the watermark like any reply). *)
  turn_ref : Ids.Turn_ref.t option;
      (* RFC-0233 §7: "<trace_id>#<absolute_turn>" join key for the turn
         that produced this row.  Stamped by [append_turn] /
         [append_assistant_message] when the caller supplies it; [None] on
         inbound user lines (no turn yet) and rows written before §7.  A
         malformed persisted value is reported as a persistence read drop
         and reads as [None]; the row stays valid. *)
}

let redaction_for ~base_dir ~keeper_name =
  Keeper_secret_redaction.snapshot ~base_path:base_dir ~keeper_name

let redact_attachment redaction att =
  { att with data = Keeper_secret_redaction.redact_text redaction att.data }

let persisted_attachment_ref (att : attachment) =
  let digest = Digest.to_hex (Digest.string att.data) in
  Printf.sprintf "masc://attachment/%s/%s" att.id digest

let persisted_attachment (att : attachment) =
  { att with data = persisted_attachment_ref att }

let redact_tool_call redaction tc =
  { tc with args = Keeper_secret_redaction.redact_text redaction tc.args }

let redact_string redaction value =
  Keeper_secret_redaction.redact_text redaction value

let redact_string_opt redaction =
  Option.map (redact_string redaction)

let rec redact_yojson_keys redaction (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `String _ as value -> value
  | `Assoc fields ->
    (* Caller-supplied trace tool args/results can carry a secret embedded in
       a key name (e.g. a header/param used as a dict key), not only in
       values. Keeper_secret_redaction.redact_json owns value and sensitive-key
       value redaction; this pass only scrubs projected secret literals in
       field names. *)
    `Assoc
      (List.map
         (fun (key, value) ->
           redact_string redaction key, redact_yojson_keys redaction value)
         fields)
  | `List items -> `List (List.map (redact_yojson_keys redaction) items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as value -> value

let redact_trace_json redaction json =
  json
  |> redact_yojson_keys redaction
  |> Keeper_secret_redaction.redact_json redaction

let redact_table_cell redaction = function
  | Keeper_chat_blocks.Cell_text value ->
    Keeper_chat_blocks.Cell_text (redact_string redaction value)
  | Keeper_chat_blocks.Cell_value { v; num; muted } ->
    Keeper_chat_blocks.Cell_value { v = redact_string redaction v; num; muted }

let redact_trace_step redaction = function
  | Keeper_chat_blocks.Trace_think { text; ts; oas_block_index } ->
    Keeper_chat_blocks.Trace_think
      { text = redact_string redaction text
      ; ts = redact_string_opt redaction ts
      ; oas_block_index
      }
  | Keeper_chat_blocks.Trace_reason { text; detail; ts } ->
    Keeper_chat_blocks.Trace_reason
      { text = redact_string redaction text
      ; detail = redact_string_opt redaction detail
      ; ts = redact_string_opt redaction ts
      }
  | Keeper_chat_blocks.Trace_tool
      { name; tool_call_id; status; dur; args; result; ts; oas_block_index } ->
    Keeper_chat_blocks.Trace_tool
      { name = redact_string redaction name
      ; tool_call_id = redact_string_opt redaction tool_call_id
      ; status
      ; dur = redact_string_opt redaction dur
      ; args = Option.map (redact_trace_json redaction) args
      ; result = Option.map (redact_trace_json redaction) result
      ; ts = redact_string_opt redaction ts
      ; oas_block_index
      }

let redact_block redaction = function
  | Keeper_chat_blocks.Text { html } ->
    Keeper_chat_blocks.Text { html = redact_string redaction html }
  | Keeper_chat_blocks.Heading { html } ->
    Keeper_chat_blocks.Heading { html = redact_string redaction html }
  | Keeper_chat_blocks.Unordered_list { items } ->
    Keeper_chat_blocks.Unordered_list
      { items = List.map (redact_string redaction) items }
  | Keeper_chat_blocks.Callout { severity; html } ->
    Keeper_chat_blocks.Callout
      { severity = redact_string_opt redaction severity
      ; html = redact_string redaction html
      }
  | Keeper_chat_blocks.Table { head; rows } ->
    Keeper_chat_blocks.Table
      { head = List.map (redact_table_cell redaction) head
      ; rows = List.map (List.map (redact_table_cell redaction)) rows
      }
  | Keeper_chat_blocks.Code { cap; html; source } ->
    Keeper_chat_blocks.Code
      { cap = redact_string_opt redaction cap
      ; html = redact_string redaction html
      ; source = redact_string_opt redaction source
      }
  | Keeper_chat_blocks.Mermaid { source; caption } ->
    Keeper_chat_blocks.Mermaid
      { source = redact_string redaction source
      ; caption = redact_string_opt redaction caption
      }
  | Keeper_chat_blocks.Svg { svg; cap } ->
    Keeper_chat_blocks.Svg
      { svg = redact_string redaction svg
      ; cap = redact_string_opt redaction cap
      }
  | Keeper_chat_blocks.Voice { secs; wave; via; size; transcript; src } ->
    Keeper_chat_blocks.Voice
      { secs
      ; wave
      ; via = redact_string_opt redaction via
      ; size = redact_string_opt redaction size
      ; transcript = redact_string_opt redaction transcript
      ; src = redact_string_opt redaction src
      }
  | Keeper_chat_blocks.Attach
      { name; dims; src; svg; ph; via; size; data; mime_type; size_bytes; kind } ->
    Keeper_chat_blocks.Attach
      { name = redact_string redaction name
      ; dims = redact_string_opt redaction dims
      ; src = redact_string_opt redaction src
      ; svg = redact_string_opt redaction svg
      ; ph = redact_string_opt redaction ph
      ; via = redact_string_opt redaction via
      ; size = redact_string_opt redaction size
      ; data = redact_string_opt redaction data
      ; mime_type = redact_string_opt redaction mime_type
      ; size_bytes
      ; kind = redact_string_opt redaction kind
      }
  | Keeper_chat_blocks.Image { src; cap } ->
    Keeper_chat_blocks.Image
      { src = redact_string redaction src
      ; cap = redact_string_opt redaction cap
      }
  | Keeper_chat_blocks.Link { url; title; meta } ->
    Keeper_chat_blocks.Link
      { url = redact_string redaction url
      ; title = redact_string redaction title
      ; meta = redact_string redaction meta
      }
  | Keeper_chat_blocks.Fusion { board_post_id; run_id } ->
    Keeper_chat_blocks.Fusion
      { board_post_id = redact_string redaction board_post_id
      ; run_id = redact_string redaction run_id
      }
  | Keeper_chat_blocks.Trace { trace } ->
    Keeper_chat_blocks.Trace
      { trace = List.map (redact_trace_step redaction) trace }
  | Keeper_chat_blocks.Thinking { content; redacted } ->
    Keeper_chat_blocks.Thinking
      { content = redact_string redaction content; redacted }

let redact_blocks redaction =
  Option.map (List.map (redact_block redaction))

let redact_message redaction msg =
  let attachments =
    Option.map (List.map (redact_attachment redaction)) msg.attachments
  in
  { msg with
    content = Keeper_secret_redaction.redact_text redaction msg.content;
    attachments;
  }

let opt_string_field key = function
  | None -> []
  | Some value -> [ (key, `String value) ]

let speaker_fields = function
  | None -> []
  | Some sp ->
      opt_string_field "speaker_id" sp.speaker_id
      @ opt_string_field "speaker_name" sp.speaker_name
      @ [ ("speaker_authority", `String (authority_label sp.speaker_authority)) ]

(* RFC-0235 P1: nested ["audio"] assoc so the clip stays one unit on the
   JSONL row. Absent on rows written before voice transport; reads as
   [None] (the dashboard renders text-only, matching any non-voice turn).
   [expired] is written only when true so fresh clips stay byte-identical
   to rows written before this field existed; the history endpoint stamps
   it when the underlying MP3 has been reaped. *)
let audio_to_json a =
  let base =
    [ ("token", `String a.token)
    ; ("mime", `String a.mime)
    ; ("message_text", `String a.message_text)
    ]
  in
  let with_optional =
    base
    |> fun fs ->
    (match a.audio_url with
     | None -> fs
     | Some url -> fs @ [ ("audio_url", `String url) ])
    |> fun fs ->
    (match a.duration_sec with
     | None -> fs
     | Some d -> fs @ [ ("duration_sec", `Float d) ])
    |> fun fs ->
    (match a.device_id with
     | None -> fs
     | Some id -> fs @ [ ("device_id", `String id) ])
  in
  if a.expired then with_optional @ [ ("expired", `Bool true) ] else with_optional

let audio_fields = function
  | None -> []
  | Some a -> [ ("audio", `Assoc (audio_to_json a)) ]

let blocks_fields = function
  | None | Some [] -> []
  | Some blocks -> [ ("blocks", Keeper_chat_blocks.blocks_to_yojson blocks) ]
;;

(* R3: producer-assigned message id.  [encode_line] is the sole writer, so
   minting here makes it impossible to persist a row without an id.  The
   process-monotonic counter disambiguates the user/tool/assistant rows of
   one turn (they share a timestamp); the microsecond timestamp orders ids
   across processes.  Minted ids are persisted, so reads are deterministic
   even though the mint itself is not. *)
let message_id_counter = Atomic.make 0

let mint_message_id ~ts =
  let n = Atomic.fetch_and_add message_id_counter 1 in
  Printf.sprintf "msg-%016.0f-%d" (ts *. 1_000_000.) n

(* Rows written before R3 carry no persisted id.  Derive a stable one at
   the read boundary from the row's timestamp and content so the dashboard
   keys off a single deterministic id and never synthesises an
   index-derived one that shifts when history pages are merged.  Two
   byte-identical legacy rows collapse to the same id, which is acceptable:
   they are indistinguishable and predate the per-row identity. *)
let legacy_message_id ~ts ~content =
  let ts_part =
    match ts with
    | Some t -> Printf.sprintf "%016.0f" (t *. 1_000_000.)
    | None -> "nots"
  in
  Printf.sprintf "legacy-%s-%s" ts_part
    (String.sub (Digest.to_hex (Digest.string content)) 0 12)

let encode_line ~(role : Role.t) ~content ~ts ?attachments ?tool_call_id
    ?tool_call_name ?surface ?conversation_id ?external_message_id ?speaker
    ?audio ?blocks ?(mentions = []) ?(kind = Row_kind.Utterance) ?turn_ref ()
    : string =
  (* RFC-0232 P5: the label is a derivation of the typed surface — the
     single site that turns a [Surface_ref.t] into the legacy [source]
     string. *)
  let source = Option.map Surface_ref.lane_label surface in
  let surface_field =
    match surface with
    | None -> []
    | Some s -> [ ("surface", Surface_ref.to_json s) ]
  in
  let base_fields = [
    ("id", `String (mint_message_id ~ts));
    ("role", `String (Role.to_label role));
    ("content", `String content);
    ("ts", `Float ts);
  ] in
  (* Backend-driven chat blocks: assistant rows get a default parse unless
     the caller already supplied blocks (e.g., a future rich-content path).
     Tool and user rows carry no blocks. *)
  let blocks =
    match blocks with
    | Some _ -> blocks
    | None ->
      if Role.equal role Role.Assistant && String.trim content <> ""
      then Some (Keeper_chat_blocks.parse_text_to_blocks content)
      else None
  in
  let mention_fields =
    match mentions with
    | [] -> []
    | ids ->
        [ ( "mentions",
            `List
              (List.map
                 (fun id ->
                   `String (Keeper_identity.Keeper_id.to_string id))
                 ids) )
        ]
  in
  let attachment_fields =
    match attachments with
    | None | Some [] -> []
    | Some atts ->
        let att_json = List.map (fun (att : attachment) ->
          `Assoc [
            ("id", `String att.id);
            ("type", `String att.att_type);
            ("name", `String att.name);
            ("size", `Int att.size);
            ("mime_type", `String att.mime_type);
            ("data", `String att.data);
          ]
        ) atts in
        [("attachments", `List att_json)]
  in
  (* Utterance is the absent-field default so rows written before the
     [kind] field existed and ordinary rows stay byte-identical. *)
  let kind_field =
    match kind with
    | Row_kind.Utterance -> []
    | Row_kind.Transport_failure ->
        [ ("kind", `String (Row_kind.to_label kind)) ]
  in
  let all_fields =
    base_fields
    @ attachment_fields
    @ mention_fields
    @ kind_field
    @ opt_string_field "tool_call_id" tool_call_id
    @ opt_string_field "tool_call_name" tool_call_name
    @ opt_string_field "source" source
    @ surface_field
    @ opt_string_field "conversation_id" conversation_id
    @ opt_string_field "external_message_id" external_message_id
    @ speaker_fields speaker
    @ audio_fields audio
    @ blocks_fields blocks
    @ opt_string_field "turn_ref" (Option.map Ids.Turn_ref.to_string turn_ref)
  in
  Yojson.Safe.to_string (`Assoc all_fields)

(* Tool calls with empty accumulated arguments are normalised to "{}" so
   every persisted line keeps a non-empty [content] (the read-side
   validity check and the dashboard history mapping both require it). *)
let normalize_tool_args args =
  if String.trim args = "" then "{}" else args

let normalize_tool_call_id ~position call_id =
  if String.trim call_id = "" then Printf.sprintf "tc-%d" position else call_id

(* RFC-0232 §3.3: the append IS the parse boundary.  Mentions are
   derived from the content that is actually persisted (post-redaction),
   so an offline re-parse of the stored line reproduces the field;
   connectors with structured mention data add [extra_mentions]. *)
let user_line_mentions ~extra_mentions content =
  Keeper_lane_mentions.mention_ids_of_content content @ extra_mentions
  |> List.sort_uniq Keeper_identity.Keeper_id.compare

let append_turn ~base_dir ~keeper_name ~(user_content : string)
    ~(user_attachments : attachment list) ?(tool_calls = []) ?surface
    ?conversation_id ?external_message_id ?speaker ?(extra_mentions = [])
    ?(assistant_kind = Row_kind.Utterance)
    ?blocks
    ?turn_ref
    ~(assistant_content : string)
    () =
  try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let user_content =
      Keeper_secret_redaction.redact_text redaction user_content
    in
    let user_attachments =
      List.map (redact_attachment redaction) user_attachments
    in
    let persisted_user_attachments =
      List.map persisted_attachment user_attachments
    in
    let tool_calls = List.map (redact_tool_call redaction) tool_calls in
    let assistant_content =
      Keeper_secret_redaction.redact_text redaction assistant_content
    in
    let blocks = redact_blocks redaction blocks in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    (* Speaker identity belongs to the user line only: tool and
       assistant lines are the keeper's own output. *)
    let user_line =
      encode_line ~role:Role.User ~content:user_content ~ts
        ~attachments:persisted_user_attachments ?surface ?conversation_id
        ?external_message_id ?speaker ?turn_ref
        ~mentions:(user_line_mentions ~extra_mentions user_content) ()
    in
    let tool_lines =
      List.mapi
        (fun position tc ->
          encode_line ~role:Role.Tool
            ~content:(normalize_tool_args tc.args)
            ~ts
            ~tool_call_id:(normalize_tool_call_id ~position tc.call_id)
            ~tool_call_name:tc.call_name
            ?surface ?conversation_id ?turn_ref ())
        tool_calls
    in
    let asst_line =
      encode_line ~role:Role.Assistant ~content:assistant_content ~ts ?surface
        ?conversation_id ~kind:assistant_kind ?blocks ?turn_ref ()
    in
    let payload =
      String.concat "\n" ((user_line :: tool_lines) @ [ asst_line ]) ^ "\n"
    in
    Fs_compat.append_file path payload
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    Log.Keeper.warn "keeper_chat_store: append failed for %s: %s"
      (sanitize_name keeper_name) (Printexc.to_string exn)

(* RFC-0223 P4: keeper-initiated message on one lane. A single
   assistant line — there is no user turn to pair it with.

   [append_assistant_message_result] surfaces a write failure as [Error msg] so
   a caller bound by a no-silent-loss contract (e.g. {!Fusion_sink.emit}) can
   propagate it. The failure is still counted + warn-logged here so callers that
   use the unit wrapper below keep the existing swallow-and-count telemetry. *)
let append_assistant_message_result ~base_dir ~keeper_name ~(content : string)
    ?surface ?conversation_id ?audio ?blocks ?turn_ref () : (unit, string) result
    =
  try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let content = Keeper_secret_redaction.redact_text redaction content in
    let blocks = redact_blocks redaction blocks in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let line =
      encode_line ~role:Role.Assistant ~content ~ts ?surface ?conversation_id ?audio ?blocks ?turn_ref ()
    in
    Fs_compat.append_file path (line ^ "\n");
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    Log.Keeper.warn "keeper_chat_store: assistant append failed for %s: %s"
      (sanitize_name keeper_name) (Printexc.to_string exn);
    Error (Printexc.to_string exn)

(* Unit wrapper: existing callers keep the prior swallow-and-count behavior (the
   failure is already counted + logged inside the [_result] variant). New callers
   that must surface the failure call [append_assistant_message_result] directly. *)
let append_assistant_message ~base_dir ~keeper_name ~(content : string)
    ?surface ?conversation_id ?audio ?blocks ?turn_ref () =
  ignore
    (append_assistant_message_result ~base_dir ~keeper_name ~content ?surface
       ?conversation_id ?audio ?blocks ?turn_ref ()
      : (unit, string) result)

(* RFC-0226: inbound user line recorded at delivery time, before (and
   independent of) any turn. A single user line — the assistant reply,
   if one ever comes, is appended separately by the reply path. *)
let append_user_message ~base_dir ~keeper_name ~(content : string)
    ?(attachments = []) ?surface ?conversation_id ?external_message_id ?speaker
    ?(extra_mentions = []) () =
  try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let content = Keeper_secret_redaction.redact_text redaction content in
    let attachments = List.map (redact_attachment redaction) attachments in
    let persisted_attachments = List.map persisted_attachment attachments in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let line =
      encode_line ~role:Role.User ~content ~ts ?surface ?conversation_id
        ~attachments:persisted_attachments
        ?external_message_id ?speaker
        ~mentions:(user_line_mentions ~extra_mentions content) ()
    in
    Fs_compat.append_file path (line ^ "\n")
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    Log.Keeper.warn "keeper_chat_store: user append failed for %s: %s"
      (sanitize_name keeper_name) (Printexc.to_string exn)

let parse_line ~file_path (line : string) : chat_message option =
  try
    let json = Yojson.Safe.from_string line in
    let role_label =
      Json_util.get_string_with_default json ~key:"role" ~default:""
    in
    let content = Json_util.get_string_with_default json ~key:"content" ~default:"" in
    let ts =
      (try Some ((match Json_util.assoc_member_opt "ts" json with Some (`Float f) -> f | _ -> 0.0))
       with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None) in
    let opt_string key =
      match Json_util.assoc_member_opt key json with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ -> None
    in
    let tool_call_id = opt_string "tool_call_id" in
    let tool_call_name = opt_string "tool_call_name" in
    let source = opt_string "source" in
    let surface =
      match Json_util.assoc_member_opt "surface" json with
      | None -> None
      | Some surface_json -> (
          match Surface_ref.of_json surface_json with
          | Ok s -> Some s
          | Error detail ->
              (* Unknown/invalid surface payload: surface it, keep the
                 row (the label in [source] still renders). *)
              report_persistence_read_drop
                ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                ~path:file_path
                ~detail:(Printf.sprintf "invalid surface field: %s" detail);
              None)
    in
    let conversation_id = opt_string "conversation_id" in
    let external_message_id = opt_string "external_message_id" in
    let speaker =
      let speaker_id = opt_string "speaker_id" in
      let speaker_name = opt_string "speaker_name" in
      match opt_string "speaker_authority" with
      | Some label -> (
          match authority_of_label label with
          | Some speaker_authority ->
              Some { speaker_id; speaker_name; speaker_authority }
          | None ->
              (* Unknown authority label: surface it instead of guessing
                 a class; the row itself stays valid. *)
              report_persistence_read_drop
                ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                ~path:file_path
                ~detail:
                  (Printf.sprintf "unknown speaker_authority %S" label);
              None)
      | None ->
          (match speaker_id, speaker_name with
           | None, None -> ()
           | _ ->
               (* id/name without an authority class never comes from our
                  writer; report so the producer gets fixed. *)
               report_persistence_read_drop
                 ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                 ~path:file_path
                 ~detail:"speaker_id/speaker_name without speaker_authority");
          None
    in
    let audio =
      match Json_util.assoc_member_opt "audio" json with
      | Some (`Assoc fields) ->
          let get k =
            match List.assoc_opt k fields with
            | Some (`String s) -> Some s
            | _ -> None
          in
          (match get "token", get "mime" with
           | Some token, Some mime ->
               let duration_sec =
                 match List.assoc_opt "duration_sec" fields with
                 | Some (`Float f) -> Some f
                 | _ -> None
               in
               let message_text = Option.value (get "message_text") ~default:"" in
               let audio_url = get "audio_url" in
               let device_id = get "device_id" in
               let expired =
                 match List.assoc_opt "expired" fields with
                 | Some (`Bool b) -> b
                 | _ -> false
               in
               Some { token; audio_url; mime; duration_sec; message_text; device_id; expired }
           | _ ->
               (* audio without token+mime is malformed; drop the field but
                  keep the row (text-only render). *)
               report_persistence_read_drop
                 ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                 ~path:file_path
                 ~detail:"audio field missing token/mime";
               None)
      | _ -> None
    in
    let attachments =
      match Json_util.assoc_member_opt "attachments" json with
      | Some (`List att_list) ->
          let atts = List.filter_map (fun att_json ->
            match att_json with
            | `Assoc _ ->
                (try
                  let id = Json_util.get_string_with_default att_json ~key:"id" ~default:"" in
                  let att_type = Json_util.get_string_with_default att_json ~key:"type" ~default:"" in
                  let name = Json_util.get_string_with_default att_json ~key:"name" ~default:"" in
                  let size = (match Json_util.assoc_member_opt "size" att_json with
                    | Some (`Int i) -> i | _ -> 0) in
                  let mime_type = Json_util.get_string_with_default att_json ~key:"mime_type" ~default:"" in
                  let data = Json_util.get_string_with_default att_json ~key:"data" ~default:"" in
                  if id = "" || data = "" then None
                  else Some { id; att_type; name; size; mime_type; data }
                with _ -> None)
            | _ -> None
          ) att_list in
          if atts = [] then None else Some atts
      | _ -> None
    in
    let mentions =
      (* Absent field = pre-P4 row or no mentions; both read as [].
         Entries that cannot mint an id are reported and skipped — the
         row itself stays valid (losing one malformed mention must not
         drop the whole line from the lane). *)
      match Json_util.assoc_member_opt "mentions" json with
      | None -> []
      | Some (`List items) ->
          List.filter_map
            (fun item ->
              match item with
              | `String value -> (
                  match Keeper_identity.Keeper_id.of_string value with
                  | Some _ as id -> id
                  | None ->
                      report_persistence_read_drop
                        ~reason:
                          Safe_ops.persistence_read_drop_reason_invalid_payload
                        ~path:file_path
                        ~detail:
                          (Printf.sprintf "empty mention entry %S" value);
                      None)
              | _ ->
                  report_persistence_read_drop
                    ~reason:
                      Safe_ops.persistence_read_drop_reason_invalid_payload
                    ~path:file_path
                    ~detail:"non-string mention entry";
                  None)
            items
      | Some _ ->
          report_persistence_read_drop
            ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
            ~path:file_path
            ~detail:"mentions field is not a list";
          []
    in
    let blocks =
      match Json_util.assoc_member_opt "blocks" json with
      | None -> None
      | Some blocks_json -> (
          match Keeper_chat_blocks.blocks_of_yojson blocks_json with
          | Some _ as blocks -> blocks
          | None ->
              report_persistence_read_drop
                ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                ~path:file_path
                ~detail:"invalid blocks field";
              None)
    in
    let kind =
      (* Absent field = every row written before [kind] existed; all of
         those are utterances. Unknown labels are surfaced and read as
         [Utterance] — the conservative arm (renders and advances the
         watermark like any reply) rather than silently resurrecting a
         pending user line. *)
      match opt_string "kind" with
      | None -> Row_kind.Utterance
      | Some label -> (
          match Row_kind.of_label label with
          | Some kind -> kind
          | None ->
              report_persistence_read_drop
                ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                ~path:file_path
                ~detail:(Printf.sprintf "unknown chat row kind %S" label);
              Row_kind.Utterance)
    in
    let turn_ref =
      (* RFC-0233 §7: parse the join key; a malformed value is surfaced as
         a read drop and reads as [None] — never repaired. *)
      match opt_string "turn_ref" with
      | None -> None
      | Some s -> (
          match Ids.Turn_ref.of_string s with
          | Some _ as tr -> tr
          | None ->
              report_persistence_read_drop
                ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                ~path:file_path
                ~detail:(Printf.sprintf "invalid turn_ref %S" s);
              None)
    in
    if role_label = "" || content = "" then (
      report_persistence_read_drop
        ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
        ~path:file_path
        ~detail:"chat row missing non-empty role/content";
      None)
    else
      match Role.of_label role_label with
      | None ->
          (* RFC-0232 P1: an unknown role cannot participate in any lane
             semantics (watermark, pending, rendering); surface it
             instead of carrying an untyped row. *)
          report_persistence_read_drop
            ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
            ~path:file_path
            ~detail:(Printf.sprintf "unknown chat row role %S" role_label);
          None
      | Some Role.Tool when tool_call_name = None ->
          report_persistence_read_drop
            ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
            ~path:file_path
            ~detail:"tool chat row missing non-empty tool_call_name";
          None
      | Some role ->
          let id =
            match opt_string "id" with
            | Some persisted -> persisted
            | None -> legacy_message_id ~ts ~content
          in
          Some
            { id; role; content; ts; attachments; tool_call_id; tool_call_name;
              source; surface; conversation_id; external_message_id; speaker;
              audio; blocks; mentions; kind; turn_ref }
  with Yojson.Json_error detail ->
    report_persistence_read_drop
      ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
      ~path:file_path
      ~detail;
    None

(* Window bounds for [load]. [max_history] counts user/assistant
   messages only, so tool lines never shrink the visible conversation
   depth. [max_total_lines] is the absolute guard (tool lines included)
   against a pathological tool-spam turn blowing up the payload. *)
let max_history = 100
let max_total_lines = 400

let is_tool_message (msg : chat_message) = Role.equal msg.role Role.Tool

(* A turn is persisted as user, tool*, assistant. Evicting the front of
   the window can leave tool lines whose owning user line is gone;
   render-wise they are orphans, so trim them. *)
let rec drop_leading_tool_messages = function
  | msg :: rest when is_tool_message msg -> drop_leading_tool_messages rest
  | messages -> messages

(* RFC-0226 P2: [load] serves a fixed window ([max_total_lines]) but
   used to read and JSON-parse the whole file to build it, so its cost
   scaled with lane size — the same pathology family as the
   2026-06-09 telemetry-JSONL incident (multi-MB files starving the
   Eio domain). Read a bounded tail instead: [max_total_lines] lines
   at ~10 KiB each leaves wide slack over the gate's 4 KB content
   bound. A tail whose recent lines are larger (attachment payloads)
   degrades to a shorter window, never to an error or a full scan. *)
let tail_read_bytes = 4 * 1024 * 1024

(* RFC-0228 P1: binary-search probes for [before]-paging are tiny
   bounded reads; a probe only needs to span a handful of lines. A
   probe landing inside an oversized line degrades the cut estimate
   (shorter window), never correctness — the final ts filter discards
   overshoot rows. *)
let probe_bytes = 256 * 1024

type page = { messages : chat_message list; has_more : bool }

(* Lines of the byte slice [[from, upto)). When [from > 0] the first
   element is a (potentially partial) line fragment — dropped, same
   rationale as the RFC-0226 P2 tail read. A final element without a
   terminating '\n' (mid-line [upto], or a writer-in-flight tail) is
   dropped the same way; split yields [""] there for boundary cuts, so
   only true fragments are removed. *)
let slice_lines ~path ~from ~upto : string list =
  if upto <= from then []
  else
    let slice = Fs_compat.read_slice ~path ~from ~len:(upto - from) in
    let lines = String.split_on_char '\n' slice in
    let lines = match lines with _ :: rest when from > 0 -> rest | l -> l in
    match List.rev lines with
    | last :: rev_rest when last <> "" -> List.rev rev_rest
    | _ -> lines

(* Metric-quiet ts extractor for probes: probed lines are re-read by
   the real parse later, so a malformed row must not double-count in
   the read-drop metrics. *)
let quiet_line_ts line : float option =
  try
    match Json_util.assoc_member_opt "ts" (Yojson.Safe.from_string line) with
    | Some (`Float f) -> Some f
    | _ -> None
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> None

let probe_ts ~path ~size pos : float option =
  let upto = min size (pos + probe_bytes) in
  List.find_map
    (fun line ->
      let trimmed = String.trim line in
      if trimmed = "" then None else quiet_line_ts trimmed)
    (slice_lines ~path ~from:pos ~upto)

(* Largest prefix [[0, cut)) holding only lines with ts < [before].
   Append-only wall-clock stamps make line ts monotone in byte offset,
   so this is a plain byte-offset binary search: ~log2(size/probe)
   probes, each bounded. The returned cut overshoots by at most one
   probe window; callers filter by ts. *)
let find_cut ~path ~size ~before : int =
  let lo = ref 0 and hi = ref size in
  while !hi - !lo > probe_bytes do
    let mid = !lo + ((!hi - !lo) / 2) in
    match probe_ts ~path ~size mid with
    | Some t when t < before -> lo := mid
    | Some _ | None -> hi := mid
  done;
  !hi

let load_page ~base_dir ~keeper_name ?before () : page =
  let path = chat_path ~base_dir ~keeper_name in
  if not (Sys.file_exists path) then { messages = []; has_more = false }
  else
  try
    let size = Option.value (Fs_compat.file_size path) ~default:0 in
    let upto, keep =
      match before with
      | None -> (size, fun (_ : chat_message) -> true)
      | Some b ->
          (* Rows without ts (legacy) are unorderable and stay
             unreachable through paging; the tail window still serves
             them. *)
          ( find_cut ~path ~size ~before:b,
            fun (m : chat_message) ->
              match m.ts with Some t -> t < b | None -> false )
    in
    let from = if upto > tail_read_bytes then upto - tail_read_bytes else 0 in
    (* Single pass: keep a running window of the last [max_history]
       user/assistant messages plus their tool lines. *)
    let q = Queue.create () in
    let primary_count = ref 0 in
    let evicted = ref false in
    let pop_front () =
      evicted := true;
      let popped = Queue.pop q in
      if not (is_tool_message popped) then decr primary_count
    in
    List.iter
      (fun line ->
        let trimmed = String.trim line in
        if trimmed <> "" then
          match parse_line ~file_path:path trimmed with
          | Some msg when keep msg ->
              Queue.push msg q;
              if not (is_tool_message msg) then incr primary_count;
              while
                !primary_count > max_history
                || Queue.length q > max_total_lines
              do
                pop_front ()
              done
          | Some _ | None -> ())
      (slice_lines ~path ~from ~upto);
    let messages =
      let redaction = redaction_for ~base_dir ~keeper_name in
      Queue.fold (fun acc msg -> msg :: acc) [] q
      |> List.rev
      |> drop_leading_tool_messages
      |> List.map (redact_message redaction)
    in
    { messages; has_more = from > 0 || !evicted }
  with
  | Sys_error detail ->
      report_persistence_read_drop
        ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
        ~path
        ~detail;
      { messages = []; has_more = false }
  | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ChatStoreFailures)
        ~labels:[("operation", Keeper_chat_store_operation.(to_label Load))]
        ();
      Log.Keeper.warn "keeper_chat_store: load failed for %s: %s"
        (sanitize_name keeper_name) (Printexc.to_string exn);
      { messages = []; has_more = false }

let load ~base_dir ~keeper_name : chat_message list =
  (load_page ~base_dir ~keeper_name ()).messages

(* RFC-0235 P3: the history endpoint can tell the dashboard that a clip
   has been reaped by checking the same audio directory the synthesis side
   writes to. This keeps the TTL reaper simple while avoiding a broken
   native player on reload. *)
let audio_clip_file_path ~base_dir token =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) "audio")
    (token ^ ".mp3")

let valid_audio_token token =
  Re.execp (Re.compile (Re.Pcre.re "^[A-Za-z0-9_-]+$")) token

let file_exists_safe path =
  try Sys.file_exists path with
  | Sys_error _ | Unix.Unix_error _ -> false

let audio_fields_with_expired ~base_dir audio =
  match audio with
  | None -> []
  | Some a ->
      let expired =
        if not (valid_audio_token a.token) then true
        else
          match base_dir with
          | None -> a.expired
          | Some base_dir ->
              a.expired
              || not (file_exists_safe (audio_clip_file_path ~base_dir a.token))
      in
      [ ("audio", `Assoc (audio_to_json { a with expired })) ]

let blocks_with_trace ~trace_block_by_turn_ref (m : chat_message) =
  let base =
    match m.blocks with
    | Some blocks -> blocks
    | None -> []
  in
  match m.role, m.turn_ref, trace_block_by_turn_ref with
  | Role.Assistant, Some turn_ref, Some trace_block_by_turn_ref -> (
      match trace_block_by_turn_ref turn_ref with
      | Some trace_block -> base @ [ trace_block ]
      | None -> base)
  | _ -> base

let blocks_fields_of_list = function
  | [] -> []
  | blocks -> [ ("blocks", Keeper_chat_blocks.blocks_to_yojson blocks) ]
;;

let to_json_array ?base_dir ?trace_block_by_turn_ref
    (messages : chat_message list) : Yojson.Safe.t =
  `List
    (List.map
       (fun m ->
         `Assoc
           ([ ("id", `String m.id);
              ("role", `String (Role.to_label m.role));
              ("content", `String m.content);
            ] @ (match m.ts with
                 | Some t -> [("ts", `Float t)]
                 | None -> [])
              (* Dashboard history: surface the writer-declared kind for
                 non-utterance rows so a reload can tell a transport
                 failure apart from keeper speech. *)
              @ (match m.kind with
                 | Row_kind.Utterance -> []
                 | Row_kind.Transport_failure ->
                     [ ("kind", `String (Row_kind.to_label m.kind)) ])
              @ opt_string_field "tool_call_id" m.tool_call_id
              @ opt_string_field "tool_call_name" m.tool_call_name
              @ opt_string_field "source" m.source
              (* RFC-0232 P5: re-emit the structured surface so a history
                 reload restores the connector deep-link, not only the
                 derived [source] lane label. [encode_line] persists it with
                 the same [Surface_ref.to_json] and [load] decodes it back
                 into [m.surface]; this read-serve site had dropped it, so
                 [surfaceLink] in the dashboard rendered nothing on reload. *)
              @ (match m.surface with
                 | None -> []
                 | Some s -> [ ("surface", Surface_ref.to_json s) ])
              @ opt_string_field "conversation_id" m.conversation_id
              @ opt_string_field "external_message_id" m.external_message_id
              @ speaker_fields m.speaker
              @ (match m.attachments with
                 | None | Some [] -> []
                 | Some atts ->
                     let att_json = List.map (fun (att : attachment) ->
                       `Assoc [
                         ("id", `String att.id);
                         ("type", `String att.att_type);
                         ("name", `String att.name);
                         ("size", `Int att.size);
                         ("mime_type", `String att.mime_type);
                         ("data", `String att.data);
                       ]
                     ) atts in
                     [("attachments", `List att_json)])
              @ audio_fields_with_expired ~base_dir m.audio
              @ blocks_fields_of_list (blocks_with_trace ~trace_block_by_turn_ref m)
              @ opt_string_field "turn_ref"
                  (Option.map Ids.Turn_ref.to_string m.turn_ref)))
       messages)

(* RFC-0233 §7: a turn's transcript derived by an exact join on the
   persisted [turn_ref] ("<trace_id>#<absolute_turn>"). The inspector
   needs the operator request that opened the turn and the keeper reply
   it produced; both are stamped with the same turn_ref by
   {!append_turn} on the dashboard reply path
   (server_routes_http_keeper_stream.ml). Tool rows are excluded — they
   carry only the call args, while the full tool I/O (input + output) is
   surfaced by the tool-call store keyed on [execution_id]. *)
type turn_transcript = {
  user : chat_message list;
  assistant : chat_message list;
}

let transcript_of_messages (messages : chat_message list) ~turn_ref :
    turn_transcript =
  let matches (m : chat_message) =
    match m.turn_ref with
    | Some tr -> Ids.Turn_ref.equal tr turn_ref
    | None -> false
  in
  let user, assistant =
    List.fold_left
      (fun (user, assistant) (m : chat_message) ->
        if not (matches m) then (user, assistant)
        else
          match m.role with
          | Role.User -> (m :: user, assistant)
          | Role.Assistant -> (user, m :: assistant)
          (* Tool rows join via execution_id in the tool-call store, not
             via the transcript. *)
          | Role.Tool -> (user, assistant))
      ([], []) messages
  in
  { user = List.rev user; assistant = List.rev assistant }

let transcript_line_to_json (m : chat_message) : Yojson.Safe.t =
  `Assoc
    ([ ("role", `String (Role.to_label m.role));
       ("content", `String m.content);
     ]
    @ (match m.ts with Some t -> [ ("ts", `Float t) ] | None -> [])
      (* Surface the writer-declared kind so the inspector can tell a
         transport failure apart from a real keeper utterance, exactly as
         the chat history endpoint does — a failure marker is never quoted
         back as the keeper's own words. *)
    @ (match m.kind with
       | Row_kind.Utterance -> []
       | Row_kind.Transport_failure ->
           [ ("kind", `String (Row_kind.to_label m.kind)) ]))

let turn_transcript_to_json ~keeper ~turn_ref (t : turn_transcript) :
    Yojson.Safe.t =
  (* [found] is false when no persisted row carries this turn_ref (old
     rows, rows outside the retained window, or a turn that produced no
     chat lines). The caller renders explicit absence, never a fabricated
     transcript. *)
  let found = t.user <> [] || t.assistant <> [] in
  `Assoc
    [ ("keeper", `String keeper);
      ("turn_ref", `String (Ids.Turn_ref.to_string turn_ref));
      ("found", `Bool found);
      ("source", `String "keeper_chat_store");
      ("user", `List (List.map transcript_line_to_json t.user));
      ("assistant", `List (List.map transcript_line_to_json t.assistant));
    ]
