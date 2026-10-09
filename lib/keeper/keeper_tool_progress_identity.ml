(** Opaque tool I/O fingerprints for observability. *)

type io_fingerprints =
  { input_fingerprint : string
  ; output_fingerprint : string
  }

let sort_json_fields fields =
  List.stable_sort (fun (left, _) (right, _) -> String.compare left right) fields
;;

let rec normalize_json = function
  | `Assoc fields ->
    fields
    |> List.map (fun (key, value) -> key, normalize_json value)
    |> sort_json_fields
    |> fun fields -> `Assoc fields
  | `List items -> `List (List.map normalize_json items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as json -> json
;;

let sha256_hex raw = Digestif.SHA256.(digest_string raw |> to_hex)

let digest_json json =
  json |> normalize_json |> Yojson.Safe.to_string |> sha256_hex
;;

let redacted_input input =
  input
  |> Observability_redact.redact_json_value
  |> Observability_redact.redact_json_strings
;;

(* The log projection deliberately masks keys containing [token]. A page
   cursor is still an input distinction for the repeated-call detector: five
   advancing pages must not look like five identical calls. Keep only a
   digest of this exact cursor field in the private identity projection;
   never restore it below a secret-bearing parent or in observability JSON. *)
let rec retain_page_cursor_identity original redacted =
  match original, redacted with
  | `Assoc original_fields, `Assoc redacted_fields ->
    `Assoc
      (List.map2
         (fun (key, value) (redacted_key, redacted_value) ->
           if String.equal key "next_page_token"
           then
             (match value with
              | `String cursor ->
                redacted_key, `String ("[cursor-sha256:" ^ sha256_hex cursor ^ "]")
              | _ -> redacted_key, redacted_value)
           else if Secret_patterns.is_sensitive_key key
                   || Secret_patterns.key_suggests_secret key
           then redacted_key, redacted_value
           else
             redacted_key, retain_page_cursor_identity value redacted_value)
         original_fields redacted_fields)
  | `List original_items, `List redacted_items ->
    `List (List.map2 retain_page_cursor_identity original_items redacted_items)
  | _ -> redacted
;;

(* The registered operator-confirm schema identifies a pending action by its
   top-level [confirm_token]. Its opaque identity must survive log masking,
   just as advancing cursors do. The schema does not give that meaning to
   nested fields or to other tools' similarly named credentials. *)
let retain_confirmation_identity ~tool_name original redacted =
  match tool_name, original, redacted with
  | "masc_operator_confirm", `Assoc fields, `Assoc redacted_fields ->
    `Assoc (List.map2
      (fun (key, value) (visible_key, visible_value) ->
        match key, value with
        | "confirm_token", `String token ->
          visible_key, `String ("[action-sha256:" ^ sha256_hex token ^ "]")
        | _ -> visible_key, visible_value)
      fields redacted_fields)
  | _ -> redacted
;;

(* A memory write returns the content-addressed [memory_id]; a retract
   receives that id as input. The answer therefore groups changing write
   requests and snapshot stamps by the claim they affect. *)
type memory_identity = Memory_write of string | Memory_retract of string

let memory_id_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "memory_id" fields with
     | Some (`String memory_id) -> Some memory_id
     | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _)
     | None -> None)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    None
;;

let memory_identity ~tool_name ~input ~output_text =
  match Keeper_tool_answer.resolve tool_name with
  | Keeper_tool_answer.Keeper_handler Keeper_tool_descriptor.Tool_memory_write ->
    Option.bind
      (Keeper_tool_answer.answer ~tool_name ~output_text)
      memory_id_of_json
    |> Option.map (fun memory_id -> Memory_write memory_id)
  | Keeper_tool_answer.Keeper_handler Keeper_tool_descriptor.Tool_memory_retract ->
    Option.map (fun memory_id -> Memory_retract memory_id)
      (memory_id_of_json input)
  | Keeper_tool_answer.Keeper_handler _ | Keeper_tool_answer.Outside_keeper_descriptors ->
    None
;;

let memory_identity_fingerprint = function
  | Memory_write memory_id ->
    digest_json (`Assoc [ "tool", `String "write"; "memory_id", `String memory_id ])
  | Memory_retract memory_id ->
    digest_json (`Assoc [ "tool", `String "retract"; "memory_id", `String memory_id ])
;;

let digest_tool_input ~tool_name input =
  redacted_input input
  |> retain_page_cursor_identity input
  |> retain_confirmation_identity ~tool_name input
  |> digest_json
  |> Option.some
;;

let stored_output_identity_json ~sha256 ~bytes ~mime =
  `Assoc
    [ "kind", `String "stored"
    ; "sha256", `String sha256
    ; "bytes", `Int bytes
    ; "mime", `String mime
    ]
;;

(* What is hashed is the tool's answer, not its receipt. A field that changes
   on every call -- Execute's execution time, a memory write's snapshot
   revision and timestamp -- would otherwise make two identical results hash
   apart, and the repeated-call yield in keeper_agent_run.ml (threshold 3)
   would never see the loop: [gh auth status] four times on 2026-08-24, twelve
   memory claims rewritten 1,861 times on 2026-10-05. Which part of an output
   is the answer is the tool's to say ({!Keeper_tool_answer}); this module
   names no field. A tool that reads the whole output as its answer keeps the
   canonical JSON digest, and output that is not JSON keeps the byte hash. *)
let inline_output_fingerprint value =
  match Yojson.Safe.from_string value with
  | json -> Some (digest_json json)
  | exception Yojson.Json_error _ ->
    let text =
      value
      |> Safe_ops.sanitize_text_utf8
      |> Observability_redact.redact_preview ~max_len:4000
    in
    Some (sha256_hex text)
;;

let output_fingerprint ~tool_name output_text =
  match Tool_output.decode_from_agent_core output_text with
  | Tool_output.Decoded { sha256; bytes; mime; _ } ->
    Some (digest_json (stored_output_identity_json ~sha256 ~bytes ~mime))
  | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
    (match Keeper_tool_answer.answer ~tool_name ~output_text with
     | Some answer -> Some (digest_json answer)
     | None -> inline_output_fingerprint output_text)
;;

let digest_tool_output ~tool_name output_text =
  output_fingerprint ~tool_name output_text
;;

let compute_tool_io ~tool_name ~input ~output_text =
  match memory_identity ~tool_name ~input ~output_text with
  | Some identity ->
    let fingerprint = memory_identity_fingerprint identity in
    Some { input_fingerprint = fingerprint; output_fingerprint = fingerprint }
  | None ->
    (match digest_tool_input ~tool_name input, digest_tool_output ~tool_name output_text with
     | Some input_fingerprint, Some output_fingerprint ->
       Some { input_fingerprint; output_fingerprint }
     | None, _ | _, None -> None)
;;

(* Answers already computed, kept because the same questions come back. The
   live hook asks once per executed call, and the next turn's history walk asks
   again for that call when [History_memo] does not hold it yet: a keeper's
   first walk in this process, or the calls of its last turn.

   The key is what the answer depends on, not the [tool_use_id] the call
   arrived under. [Keeper_checkpoint_purge.clear_tool_result_blocks] replaces
   a result's body with a placeholder and keeps the id, and the next turn
   reads that rewritten body back off disk -- an id-keyed entry would answer
   for bytes that are gone. Keyed on the bytes, a rewritten body misses and
   is computed once more, which is the whole of the invalidation rule.

   Bounded in bytes rather than entries because the key holds [output_text]
   and one tool output can be large. Eviction is oldest-inserted, so the calls
   of the last turns stay while older bodies, which [History_memo] holds for
   the histories that still name them, go first. *)
module Io_memo = struct
  (* The live calls of recent turns across all keepers: the 8,660 pairs of one
     live history averaged 3.9 KB of input and output (2026-09-15), so this
     holds fewer than 2,200 such calls. A whole history is [History_memo]'s to keep. *)
  let capacity_bytes = 8 * 1024 * 1024

  module Key = struct
    type t =
      { tool_name : string
      ; input : Yojson.Safe.t
      ; output_text : string
      }

    let equal left right =
      String.equal left.tool_name right.tool_name
      && String.equal left.output_text right.output_text
      && left.input = right.input
    ;;

    (* [Hashtbl.hash] on the record walks the fields in order under a node
       budget, and [input] can spend the whole budget before [output_text] is
       reached. The histories this memo is for are largely one tool polled
       with one input and a different answer each time -- masc_status x308,
       keeper_tasks_list x380 in the measurement this comment's sibling above
       cites -- so those keys would agree on everything the budget saw and
       land in one bucket, where each lookup would then deep-compare its way
       down the chain. Hashing the body separately keeps them apart. *)
    let hash key =
      Hashtbl.hash
        (Hashtbl.hash key.output_text, key.tool_name, Hashtbl.hash key.input)
    ;;
  end

  type key = Key.t =
    { tool_name : string
    ; input : Yojson.Safe.t
    ; output_text : string
    }

  module Table = Hashtbl.Make (Key)

  let table : io_fingerprints option Table.t = Table.create 256
  let insertion_order : key Queue.t = Queue.create ()
  let retained_bytes = ref 0
  let lock = Stdlib.Mutex.create ()

  (* What an entry costs to keep. Constants stand for the boxed header and
     pointer of each node, so the total tracks the shape as well as the
     bytes; exactness is not needed, only that a large body counts as large.
     The constructor set is [Yojson.Safe.t] as yojson 3 defines it. *)
  let rec json_bytes = function
    | `Null | `Bool _ -> 8
    | `Int _ | `Float _ -> 16
    | `Intlit text | `String text -> 24 + String.length text
    | `List items ->
      List.fold_left (fun acc item -> acc + 24 + json_bytes item) 24 items
    | `Assoc fields ->
      List.fold_left
        (fun acc (field, value) -> acc + 40 + String.length field + json_bytes value)
        24
        fields
  ;;

  let key_bytes key =
    String.length key.tool_name + json_bytes key.input + String.length key.output_text
  ;;

  let find key =
    Stdlib.Mutex.protect lock (fun () -> Table.find_opt table key)
  ;;

  (* Two domains can compute the same key at once: the pool runs the walk and
     the owning fiber records live calls. Both answers are equal, so the
     second one is dropped rather than counted twice. *)
  let add key value =
    let bytes = key_bytes key in
    Stdlib.Mutex.protect lock (fun () ->
      if not (Table.mem table key)
      then begin
        Table.replace table key value;
        Queue.add key insertion_order;
        retained_bytes := !retained_bytes + bytes;
        while !retained_bytes > capacity_bytes && not (Queue.is_empty insertion_order) do
          let oldest = Queue.pop insertion_order in
          if Table.mem table oldest
          then begin
            Table.remove table oldest;
            retained_bytes := !retained_bytes - key_bytes oldest
          end
        done
      end)
  ;;
end

let digest_tool_io ~tool_name ~input ~output_text =
  let key = { Io_memo.tool_name; input; output_text } in
  match Io_memo.find key with
  | Some answer -> answer
  | None ->
    (* Computed outside the lock: this is the serialising and hashing the
       memo exists to stop repeating, and holding the lock across it would
       serialise every keeper's walk behind one of them. *)
    let answer = compute_tool_io ~tool_name ~input ~output_text in
    Io_memo.add key answer;
    answer
;;

type history_pair = Io_memo.key =
  { tool_name : string
  ; input : Yojson.Safe.t
  ; output_text : string
  }

(* [Keeper_run_tools_setup.seed_tool_calls_from_history] asks for every matched
   pair of a keeper's history at the start of every turn. One live keeper held
   8,660 pairs with 30.2 MB of output and 3.5 MB of input (2026-09-15), several
   times what [Io_memo] retains for every keeper together, so most of each walk
   was parsed and hashed again.

   A history memo keeps the pairs of one keeper's previous walk. A walk looks a
   pair up there, asks [digest_tool_io] for a pair it does not hold (a call the
   keeper made live last turn is still in [Io_memo]), and publishes the pairs
   it walked as the next generation. The memo is as large as the history the
   keeper already holds, and a pair that left the history, such as a purged
   body, leaves the memo with the next walk. The key is still the bytes, so a
   rewritten body misses. A published table is never written again: two walks
   of one keeper each read a finished table and the later publication wins,
   with the same answers. *)
module History_memo = struct
  type t = io_fingerprints option Io_memo.Table.t Atomic.t

  let create () : t = Atomic.make (Io_memo.Table.create 0)
end

let history_memos : (string * string, History_memo.t) Hashtbl.t = Hashtbl.create 16
let history_memos_lock = Stdlib.Mutex.create ()

let history_memo ~base_path ~keeper_name =
  Stdlib.Mutex.protect history_memos_lock (fun () ->
    match Hashtbl.find_opt history_memos (base_path, keeper_name) with
    | Some memo -> memo
    | None ->
      let memo = History_memo.create () in
      Hashtbl.replace history_memos (base_path, keeper_name) memo;
      memo)
;;

let digest_history_pairs (memo : History_memo.t) pairs =
  let previous = Atomic.get memo in
  let next = Io_memo.Table.create (List.length pairs) in
  let answers =
    List.map
      (fun (pair : history_pair) ->
         let answer =
           match Io_memo.Table.find_opt previous pair with
           | Some answer -> answer
           | None ->
             digest_tool_io
               ~tool_name:pair.tool_name
               ~input:pair.input
               ~output_text:pair.output_text
         in
         Io_memo.Table.replace next pair answer;
         answer)
      pairs
  in
  Atomic.set memo next;
  answers
;;

module For_testing = struct
end
