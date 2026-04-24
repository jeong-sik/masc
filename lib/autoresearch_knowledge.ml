(** Autoresearch_knowledge — Research finding persistence (JSONL + GraphQL).

    Records structured research findings from autoresearch loops.
    Local JSONL is the primary store; GraphQL/Neo4j is best-effort sync.

    @since 2.122.0 *)

(** {1 Types} *)

type confidence = High | Medium | Low

type finding = {
  id : string;
  loop_id : string;
  keeper_name : string;
  goal : string;
  hypothesis : string;
  evidence : string;
  conclusion : string;
  confidence : confidence;
  tags : string list;
  related_findings : string list;
  cycle_range : (int * int) option;  (** first_cycle, last_cycle *)
  timestamp : float;
}

(** {1 Serialization} *)

let confidence_to_string = function
  | High -> "high" | Medium -> "medium" | Low -> "low"

(** Partial parser for confidence labels.  Returns [None] when the input
    does not match a known level — callers that originate from user
    input (tool args, on-disk JSON) can distinguish "explicit medium"
    from "garbage or stale label" instead of silently coercing both to
    [Medium]. *)
let confidence_of_string_opt s =
  match String.lowercase_ascii (String.trim s) with
  | "high" -> Some High
  | "medium" -> Some Medium
  | "low" -> Some Low
  | _ -> None

(** Total parser kept for backward compatibility.  Falls back to
    [Medium] on unrecognised input and writes a one-line warning to
    stderr so operator typos (e.g. [confidence=hihg]) or data drift
    in stored findings surface instead of silently collapsing. *)
let confidence_of_string s =
  match confidence_of_string_opt s with
  | Some c -> c
  | None ->
    Printf.eprintf
      "[autoresearch] WARN: unrecognised confidence %S, defaulting to medium\n%!"
      s;
    Medium

let finding_to_yojson (f : finding) : Yojson.Safe.t =
  `Assoc [
    ("id", `String f.id);
    ("loop_id", `String f.loop_id);
    ("keeper_name", `String f.keeper_name);
    ("goal", `String f.goal);
    ("hypothesis", `String f.hypothesis);
    ("evidence", `String f.evidence);
    ("conclusion", `String f.conclusion);
    ("confidence", `String (confidence_to_string f.confidence));
    ("tags", `List (List.map (fun t -> `String t) f.tags));
    ("related_findings", `List (List.map (fun r -> `String r) f.related_findings));
    ("cycle_range", match f.cycle_range with
      | None -> `Null
      | Some (a, b) -> `List [`Int a; `Int b]);
    ("timestamp", `Float f.timestamp);
  ]

let finding_of_yojson (json : Yojson.Safe.t) : (finding, string) result =
  try
    let open Yojson.Safe.Util in
    let str key = member key json |> to_string in
    let str_opt key = member key json |> to_string_option in
    Ok {
      id = str "id";
      loop_id = (match str_opt "loop_id" with Some s -> s | None -> "");
      keeper_name = (match str_opt "keeper_name" with Some s -> s | None -> "unknown");
      goal = str "goal";
      hypothesis = str "hypothesis";
      evidence = str "evidence";
      conclusion = str "conclusion";
      confidence = confidence_of_string
        (match str_opt "confidence" with Some s -> s | None -> "medium");
      tags = (match member "tags" json with
              | `List l -> List.filter_map (fun v -> match v with `String s -> Some s | _ -> None) l
              | _ -> []);
      related_findings = (match member "related_findings" json with
                          | `List l -> List.filter_map (fun v -> match v with `String s -> Some s | _ -> None) l
                          | _ -> []);
      cycle_range = (match member "cycle_range" json with
        | `List [`Int a; `Int b] -> Some (a, b)
        | _ -> None);
      timestamp = (match member "timestamp" json with
                   | `Float f -> f
                   | `Int i -> float_of_int i
                   | _ -> Unix.gettimeofday ());
    }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printexc.to_string exn)

(** {1 Storage (JSONL)} *)

let findings_dir ~base_path =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path) "autoresearch")
    "findings"

let findings_file ~base_path =
  Filename.concat (findings_dir ~base_path) "findings.jsonl"

let ensure_findings_dir ~base_path =
  Fs_compat.mkdir_p (findings_dir ~base_path)

let append_finding ~base_path (f : finding) : unit =
  ensure_findings_dir ~base_path;
  let line = Yojson.Safe.to_string (finding_to_yojson f) ^ "\n" in
  Fs_compat.append_file (findings_file ~base_path) line

let load_all_findings ~base_path () : finding list =
  let path = findings_file ~base_path in
  if not (Sys.file_exists path) then []
  else
    Fs_compat.load_jsonl path
    |> List.filter_map (fun json ->
         match finding_of_yojson json with
         | Ok f -> Some f
         | Error msg ->
           Log.Keeper.warn "Skipping malformed finding: %s" msg;
           None)

let contains_ci ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 then true
  else if nlen > hlen then false
  else
    let rec scan i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else scan (i + 1)
    in
    scan 0

let rec take n = function
  | [] -> []
  | _ when n <= 0 -> []
  | x :: rest -> x :: take (n - 1) rest

let search_findings ~base_path ~query ?(limit=10) () : finding list =
  let query_lower = String.lowercase_ascii query in
  load_all_findings ~base_path ()
  |> List.rev  (* most recent first — load_all returns oldest first *)
  |> List.filter (fun f ->
    let haystack = String.lowercase_ascii
      (f.goal ^ " " ^ f.hypothesis ^ " " ^ f.evidence ^ " " ^
       f.conclusion ^ " " ^ String.concat " " f.tags) in
    contains_ci ~needle:query_lower haystack)
  |> take limit

(** {1 GraphQL Sync (best-effort)} *)

let sync_to_graphql (f : finding) : (bool, string) result =
  let mutation = {|
    mutation CreateFinding(
      $id: String!
      $goal: String!
      $hypothesis: String!
      $evidence: String!
      $conclusion: String!
      $loopId: String
      $keeperName: String
      $confidence: String
      $tags: [String!]
    ) {
      createFinding(
        id: $id
        goal: $goal
        hypothesis: $hypothesis
        evidence: $evidence
        conclusion: $conclusion
        loopId: $loopId
        keeperName: $keeperName
        confidence: $confidence
        tags: $tags
      ) {
        success
        message
        finding { findingId }
      }
    }
  |} in
  let opt_string s = if s = "" then `Null else `String s in
  let variables = `Assoc [
    ("id", `String f.id);
    ("goal", `String f.goal);
    ("hypothesis", `String f.hypothesis);
    ("evidence", `String f.evidence);
    ("conclusion", `String f.conclusion);
    ("loopId", opt_string f.loop_id);
    ("keeperName", opt_string f.keeper_name);
    ("confidence", `String (confidence_to_string f.confidence));
    ("tags", `List (List.map (fun t -> `String t) f.tags));
  ] in
  match Graphql_client.mutate ~timeout_sec:10.0 ~mutation ~variables () with
  | Ok _ -> Ok true
  | Error msg ->
    Log.Keeper.warn "Finding GraphQL sync failed (non-fatal): %s" msg;
    Error msg

(** {1 Public API} *)

let generate_finding_id () =
  Random_id.prefixed ~prefix:"fn-" ~bytes:6

let record_finding ~base_path ~(finding : finding) : Yojson.Safe.t =
  append_finding ~base_path finding;
  (* Best-effort GraphQL sync — local JSONL is authoritative *)
  let graphql_ok = match sync_to_graphql finding with
    | Ok _ -> true
    | Error _ -> false
  in
  `Assoc [
    ("ok", `Bool true);
    ("id", `String finding.id);
    ("graphql_synced", `Bool graphql_ok);
  ]
