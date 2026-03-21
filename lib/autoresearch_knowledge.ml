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

let confidence_of_string = function
  | "high" -> High | "medium" -> Medium | "low" -> Low
  | _ -> Medium

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
      tags = (try member "tags" json |> to_list |> List.map to_string
              with _ -> []);
      related_findings = (try member "related_findings" json |> to_list |> List.map to_string
                          with _ -> []);
      cycle_range = (match member "cycle_range" json with
        | `List [`Int a; `Int b] -> Some (a, b)
        | _ -> None);
      timestamp = (try member "timestamp" json |> to_float
                   with _ -> Unix.gettimeofday ());
    }
  with exn -> Error (Printexc.to_string exn)

(** {1 Storage (JSONL)} *)

let findings_dir () =
  let base = match Sys.getenv_opt "ME_ROOT" with
    | Some r -> r | None -> Sys.getenv "HOME" ^ "/me"
  in
  Filename.concat base ".masc/autoresearch/findings"

let findings_file () =
  Filename.concat (findings_dir ()) "findings.jsonl"

let ensure_findings_dir () =
  Fs_compat.mkdir_p (findings_dir ())

let append_finding (f : finding) : unit =
  ensure_findings_dir ();
  let line = Yojson.Safe.to_string (finding_to_yojson f) ^ "\n" in
  Fs_compat.append_file (findings_file ()) line

let load_all_findings () : finding list =
  let path = findings_file () in
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let findings = ref [] in
      (try while true do
        let line = input_line ic in
        if String.trim line <> "" then
          match Yojson.Safe.from_string line |> finding_of_yojson with
          | Ok f -> findings := f :: !findings
          | Error _ -> ()
      done with End_of_file -> ());
      List.rev !findings)

let search_findings ~query ?(limit=10) () : finding list =
  let query_lower = String.lowercase_ascii query in
  load_all_findings ()
  |> List.filter (fun f ->
    let haystack = String.lowercase_ascii
      (f.goal ^ " " ^ f.hypothesis ^ " " ^ f.evidence ^ " " ^
       f.conclusion ^ " " ^ String.concat " " f.tags) in
    let rec find_sub i =
      if i + String.length query_lower > String.length haystack then false
      else if String.sub haystack i (String.length query_lower) = query_lower then true
      else find_sub (i + 1)
    in
    find_sub 0)
  |> List.rev  (* most recent first *)
  |> fun results ->
    if List.length results > limit then
      List.filteri (fun i _ -> i < limit) results
    else results

(** {1 GraphQL Sync (best-effort)} *)

let sync_to_graphql (f : finding) : (bool, string) result =
  let mutation = {|
    mutation CreateFinding(
      $id: String!
      $loopId: String!
      $keeperName: String!
      $goal: String!
      $hypothesis: String!
      $evidence: String!
      $conclusion: String!
      $confidence: String!
      $tags: [String!]!
    ) {
      createFindings(input: [{
        id: $id
        loopId: $loopId
        keeperName: $keeperName
        goal: $goal
        hypothesis: $hypothesis
        evidence: $evidence
        conclusion: $conclusion
        confidence: $confidence
        tags: $tags
      }]) {
        findings { id }
      }
    }
  |} in
  let variables = `Assoc [
    ("id", `String f.id);
    ("loopId", `String f.loop_id);
    ("keeperName", `String f.keeper_name);
    ("goal", `String f.goal);
    ("hypothesis", `String f.hypothesis);
    ("evidence", `String f.evidence);
    ("conclusion", `String f.conclusion);
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
  let rnd = Mirage_crypto_rng.generate 6 in
  "fn-" ^ String.concat ""
    (List.init (String.length rnd) (fun i ->
      Printf.sprintf "%02x" (Char.code (String.get rnd i))))

let record_finding ~(finding : finding) : Yojson.Safe.t =
  append_finding finding;
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
