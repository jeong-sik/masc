(* See keeper_canary_judge.mli for the contract and for why the wire does
   not request provider-native structured output. *)

type per_fact = { category : string; recalled : bool }

type judgment = {
  judge_runtime : string;
  per_fact : per_fact list;
  recalled_count : int;
  all_recalled : bool;
  rationale : string;
}

let system_prompt =
  "You are a strict verification judge for a memory-continuity test. You \
   will be shown facts that were established earlier in a conversation, and \
   the reply an assistant gave when asked to recall all of them. Judge each \
   fact independently: recalled means the reply demonstrably contains that \
   fact's value (allowing reformatting or re-ordering, e.g. a date written \
   differently), not merely a mention of its topic. Omission, contradiction \
   or a wrong value means not recalled. Output only the requested JSON \
   object — no prose before or after it."

let compose_prompt ~(facts : Keeper_canary_facts.fact list) ~(recall_reply : string)
  : string
  =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf "Facts established earlier in the conversation:\n";
  List.iter
    (fun (f : Keeper_canary_facts.fact) ->
      Buffer.add_string buf (Printf.sprintf "- %s: %s\n" f.category f.value))
    facts;
  Buffer.add_string buf "\nThe assistant's recall reply was:\n---\n";
  Buffer.add_string buf recall_reply;
  Buffer.add_string buf "\n---\n\n";
  Buffer.add_string
    buf
    "Reply with a single JSON object and nothing else, of the exact shape:\n\
     {\"per_fact\": [{\"category\": \"<category>\", \"recalled\": \
     true|false}, ...], \"rationale\": \"<one short paragraph>\"}\n\
     Include every category listed above exactly once and no others.";
  Buffer.contents buf

(* Code-fence tolerance mirrors Fusion_judge_parse.strip_fences: providers
   frequently wrap JSON in ```json fences even when told not to, and
   rejecting that wrapper would fail runs on formatting rather than
   substance. Anything beyond a single whole-reply fence stays a parse
   error. *)
let fence = "```"
let fence_len = String.length fence

let strip_fences (s : string) : string =
  let s = String.trim s in
  if String.length s >= fence_len && String.equal (String.sub s 0 fence_len) fence
  then (
    match String.index_opt s '\n' with
    | Some nl ->
      let body = String.trim (String.sub s (nl + 1) (String.length s - nl - 1)) in
      if String.length body >= fence_len
         && String.equal (String.sub body (String.length body - fence_len) fence_len) fence
      then String.trim (String.sub body 0 (String.length body - fence_len))
      else body
    | None -> s)
  else s

let ( let* ) = Result.bind

(* The key sets are closed on both levels — the category set below is
   already exact-match, and an object contract that rejects unknown
   categories but shrugs at unknown keys would let a self-contradicting
   reply (say, a stray "verdict" field disagreeing with per_fact) pass
   unnoticed. Parse, don't validate: unknown keys are a parse error. *)
let reject_unknown_keys ~context ~allowed kvs =
  match List.find_opt (fun (k, _) -> not (List.mem k allowed)) kvs with
  | Some (k, _) -> Error (Printf.sprintf "%s: unexpected key %s" context k)
  | None -> Ok ()

let parse_per_fact_entry (j : Yojson.Safe.t) : (per_fact, string) result =
  match j with
  | `Assoc kvs ->
    let* () =
      reject_unknown_keys ~context:"per_fact entry" ~allowed:[ "category"; "recalled" ] kvs
    in
    let* category =
      match List.assoc_opt "category" kvs with
      | Some (`String s) -> Ok s
      | Some _ -> Error "per_fact entry: category is not a string"
      | None -> Error "per_fact entry: missing category"
    in
    let* recalled =
      match List.assoc_opt "recalled" kvs with
      | Some (`Bool b) -> Ok b
      | Some _ -> Error (Printf.sprintf "per_fact %s: recalled is not a boolean" category)
      | None -> Error (Printf.sprintf "per_fact %s: missing recalled" category)
    in
    Ok { category; recalled }
  | _ -> Error "per_fact entry is not an object"

let rec collect_entries acc = function
  | [] -> Ok (List.rev acc)
  | j :: rest ->
    let* entry = parse_per_fact_entry j in
    collect_entries (entry :: acc) rest

let parse_reply ~(judge_runtime : string) ~(facts : Keeper_canary_facts.fact list)
    (reply : string) : (judgment, string) result
  =
  let* json =
    match Yojson.Safe.from_string (strip_fences reply) with
    | j -> Ok j
    | exception Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
  in
  let* kvs =
    match json with
    | `Assoc kvs -> Ok kvs
    | _ -> Error "judge reply is not a JSON object"
  in
  let* () =
    reject_unknown_keys ~context:"judge reply" ~allowed:[ "per_fact"; "rationale" ] kvs
  in
  let* raw_entries =
    match List.assoc_opt "per_fact" kvs with
    | Some (`List items) -> collect_entries [] items
    | Some _ -> Error "per_fact is not a list"
    | None -> Error "missing field: per_fact"
  in
  let* rationale =
    match List.assoc_opt "rationale" kvs with
    | Some (`String s) ->
      let trimmed = String.trim s in
      if trimmed = "" then Error "rationale is empty" else Ok trimmed
    | Some _ -> Error "rationale is not a string"
    | None -> Error "missing field: rationale"
  in
  (* Exactly the run's categories, each once, no extras — then normalize to
     the run's fact order so evidence rows line up with the turns table. *)
  let expected = List.map (fun (f : Keeper_canary_facts.fact) -> f.category) facts in
  let* () =
    let seen = Hashtbl.create 16 in
    let rec check = function
      | [] -> Ok ()
      | (e : per_fact) :: rest ->
        if not (List.mem e.category expected)
        then Error (Printf.sprintf "unexpected category in judge reply: %s" e.category)
        else if Hashtbl.mem seen e.category
        then Error (Printf.sprintf "duplicate category in judge reply: %s" e.category)
        else (
          Hashtbl.add seen e.category ();
          check rest)
    in
    let* () = check raw_entries in
    let missing = List.filter (fun c -> not (Hashtbl.mem seen c)) expected in
    match missing with
    | [] -> Ok ()
    | c :: _ -> Error (Printf.sprintf "judge reply missing category: %s" c)
  in
  let per_fact =
    List.map
      (fun c ->
        (* check above guarantees exactly one entry per expected category. *)
        List.find (fun (e : per_fact) -> String.equal e.category c) raw_entries)
      expected
  in
  let recalled_count =
    List.fold_left (fun n (e : per_fact) -> if e.recalled then n + 1 else n) 0 per_fact
  in
  Ok
    { judge_runtime
    ; per_fact
    ; recalled_count
    ; all_recalled = recalled_count = List.length per_fact && per_fact <> []
    ; rationale
    }

let judgment_to_yojson (j : judgment) : Yojson.Safe.t =
  `Assoc
    [ ("judge_runtime", `String j.judge_runtime)
    ; ( "per_fact"
      , `List
          (List.map
             (fun (e : per_fact) ->
               `Assoc [ ("category", `String e.category); ("recalled", `Bool e.recalled) ])
             j.per_fact) )
    ; ("recalled_count", `Int j.recalled_count)
    ; ("all_recalled", `Bool j.all_recalled)
    ; ("rationale", `String j.rationale)
    ]
