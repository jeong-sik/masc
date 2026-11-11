(** The rows of a whole transcript: the cache of what was parsed, the two row
    readers and the captured row.

    [transcript_caches] holds, per path, the messages parsed from the part of
    the transcript that was read so far ([transcript_cache]).
    [remember_transcript], [advance_transcript] and [forget_transcript] change
    an entry under [transcript_caches_mu], and [transcript_identity] gives the device, the
    inode and the size of the file, which say whether an entry still holds.
    [parse_transcript_row_permissive] reads one line to a redacted message and
    drops a line that does not parse. [parse_transcript_row_strict] reads it
    to a message, a blank or an unreadable error at a [transcript_position].
    [parse_transcript_rows] reads the text of many rows the first way and
    [parse_transcript_rows_result] the second way, as an [Error] at the first
    unreadable row.
    A [captured_row] keeps the original line of a row, its redacted projection
    and the message read from it. [parse_transcript_captures_result] reads rows
    into the captured rows that [select] picks. [captured_row_to_json] stores
    one and [captured_row_of_json] restores it; the restore refuses a
    projection that changed more than the redacted fields.
    [Keeper_chat_store] includes this module. *)
open Keeper_chat_types
open Keeper_chat_store_line_decode

(* ── Transcript cache (RFC main-domain-scheduler-latency §8.8, P4k) ────
   [load_all] used to read the whole transcript, parse every row and redact
   every message on the calling fiber, on every keeper wake: 1.7-3.5 MB and
   2,000-3,700 rows per keeper on the live root, and the regex passes of the
   redaction alone were 19% of the main domain's busy time (2026-09-05).
   The transcript is append-only — the store's one writer appends under the
   private JSONL lock — so a load parses only the rows past the last parsed
   row boundary and appends them to what was parsed before. The cache is per
   path and holds while the file keeps its identity (device, inode), has not
   shrunk below the parsed boundary, and the redaction snapshot the messages
   were redacted with is the one in force ([redaction_for] hands back the
   same value while the secret sources are unchanged). Anything else, and a
   torn tail, reload the whole transcript through the rows reader. Parsing
   and redaction run on the domain pool when one is installed. *)
type transcript_cache =
  { device : int
  ; inode : int
  ; parsed_end : int  (** Offset just past the last parsed ['\n']-terminated row. *)
  ; messages_rev : chat_message list  (** Newest first. *)
  ; redaction : Keeper_secret_redaction.t
  }

val transcript_caches : (string, transcript_cache) Hashtbl.t

val transcript_caches_mu : Mutex.t

val remember_transcript : string -> transcript_cache -> unit

val advance_transcript : string -> from:transcript_cache -> transcript_cache -> unit
(** [advance_transcript path ~from cache] registers [cache] only while the
    table still holds [from], the very entry a load went on from. After a
    purge in between there is no entry, and after a load that finished first
    there is another one; either way nothing is registered. *)

val forget_transcript : string -> unit

val transcript_identity : string -> (int * int * int) option

type transcript_position = Line_number of int | Byte_offset of int

val parse_transcript_row_strict :
  path:string ->
  redaction:Keeper_secret_redaction.t ->
  position:transcript_position ->
  string ->
  [> `Blank
   | `Message of chat_message
   | `Unreadable of strict_decode_error ]

val parse_transcript_rows :
  path:string ->
  redaction:Keeper_secret_redaction.t ->
  string -> chat_message list

type captured_row = { raw_line : string; projected_line : string; captured_message : chat_message }

val captured_row_message : captured_row -> chat_message

val captured_row_same_source : captured_row -> captured_row -> bool

val captured_row_to_json : captured_row -> Yojson.Safe.t

val captured_row_of_json : Yojson.Safe.t -> (captured_row, string) result

val parse_transcript_captures_result :
  select:(chat_message -> bool) ->
  path:string ->
  redaction:Keeper_secret_redaction.t ->
  string ->
  (captured_row list,
   strict_decode_error)
  result

val parse_transcript_rows_result :
  path:string ->
  redaction:Keeper_secret_redaction.t ->
  string ->
  (chat_message list,
   strict_decode_error)
  result
