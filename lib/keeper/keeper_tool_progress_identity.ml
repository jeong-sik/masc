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

let digest_tool_input ~tool_name:_ input =
  Some (digest_json (redacted_input input))
;;

let stored_output_identity_json ~sha256 ~bytes ~mime =
  `Assoc
    [ "kind", `String "stored"
    ; "sha256", `String sha256
    ; "bytes", `Int bytes
    ; "mime", `String mime
    ]
;;

(* Measurement is not identity. The Execute envelope writes
   [execution_time_ms] into the payload the model reads
   (keeper_tool_execute_runtime.ml), so two byte-identical answers to the
   same command hash apart on that one field, and the repeated-call yield in
   keeper_agent_run.ml (threshold 3) could never see an Execute loop —
   observed live 2026-08-24: a keeper repeated [gh auth status] four times in
   one run, the four outputs differing only at execution_time_ms
   (1170/1471/...). Identity therefore hashes the answer: output that parses
   as JSON is digested with that field dropped at every depth. Output that is
   not JSON keeps the byte hash. *)
let measurement_field = "execution_time_ms"

let rec drop_measurement = function
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.filter (fun (key, _) -> not (String.equal key measurement_field))
       |> List.map (fun (key, value) -> key, drop_measurement value))
  | `List items -> `List (List.map drop_measurement items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as json -> json
;;

let inline_output_fingerprint value =
  match Yojson.Safe.from_string value with
  | json -> Some (digest_json (drop_measurement json))
  | exception Yojson.Json_error _ ->
    let text =
      value
      |> Safe_ops.sanitize_text_utf8
      |> Observability_redact.redact_preview ~max_len:4000
    in
    Some (sha256_hex text)
;;

let output_fingerprint output_text =
  match Tool_output.decode_from_agent_core output_text with
  | Tool_output.Decoded { sha256; bytes; mime; _ } ->
    Some (digest_json (stored_output_identity_json ~sha256 ~bytes ~mime))
  | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
    inline_output_fingerprint output_text
;;

let digest_tool_output ~tool_name:_ output_text =
  output_fingerprint output_text
;;

let compute_tool_io ~tool_name ~input ~output_text =
  match digest_tool_input ~tool_name input, digest_tool_output ~tool_name output_text with
  | Some input_fingerprint, Some output_fingerprint ->
    Some { input_fingerprint; output_fingerprint }
  | None, _ | _, None -> None
;;

(* Answers already computed, kept because the same questions come back.
   [Keeper_run_tools_setup.seed_tool_calls_from_history] walks the whole
   resumed history at the start of every turn, and [Keeper_run_context]
   re-reads the checkpoint from disk on each run, so turn N+1 serialises and
   hashes everything turn N already did. Measured on a live keeper: 1,278,158
   B of history, 55-222 ms per turn, growing with the session (#33719).

   The key is what the answer depends on, not the [tool_use_id] the call
   arrived under. [Keeper_checkpoint_purge.clear_tool_result_blocks] replaces
   a result's body with a placeholder and keeps the id, and the next turn
   reads that rewritten body back off disk -- an id-keyed entry would answer
   for bytes that are gone. Keyed on the bytes, a rewritten body misses and
   is computed once more, which is the whole of the invalidation rule.

   Bounded in bytes rather than entries because the key holds [output_text]:
   a history grows without limit and one tool output can be large. Eviction
   is oldest-inserted. The walk asks for every live entry once per turn, so
   recency separates nothing, while insertion order does put the bodies that
   have fallen out of every history first. *)
module Io_memo = struct
  (* Several times the 1.2 MB history that motivated this, so a keeper's live
     walk stays resident and eviction only reaches bodies no walk still
     names. *)
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

module For_testing = struct
end
