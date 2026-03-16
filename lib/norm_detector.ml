(** Norm Detector — Extract behavioral norms from interaction patterns.

    Scans social_motion event streams over a 7-day sliding window.
    Repeated patterns (5+ occurrences, 70%+ success rate) become
    candidate norms that can be promoted to active cultural values
    through agent voting.

    Norm lifecycle: emerging → candidate → active → fading → retired

    @since 2.90.0 *)

open Printf

(** Norm lifecycle states. *)
type norm_status =
  | Emerging    (** Detected but not yet validated *)
  | Candidate   (** Meets threshold, awaiting agent votes *)
  | Active      (** 3+ distinct agent endorsements *)
  | Fading      (** No recent activity, declining *)
  | Retired     (** Deactivated *)

let string_of_status = function
  | Emerging -> "emerging" | Candidate -> "candidate"
  | Active -> "active" | Fading -> "fading" | Retired -> "retired"

let status_of_string = function
  | "emerging" -> Emerging | "candidate" -> Candidate
  | "active" -> Active | "fading" -> Fading | _ -> Retired

(** A detected behavioral norm. *)
type norm = {
  id : string;
  pattern : string;            (** "When X, agents tend to Y" *)
  occurrence_count : int;
  success_count : int;
  success_rate : float;
  status : norm_status;
  endorsers : string list;     (** Agent names that voted for this norm *)
  detractors : string list;    (** Agent names that voted against *)
  first_seen : float;
  last_seen : float;
  summary : string;            (** Human-readable description *)
}

(* ================================================================ *)
(* Paths                                                            *)
(* ================================================================ *)

let norms_dir () =
  let me_root = Env_config.me_root () in
  Filename.concat me_root ".masc/norms"

let norms_path () =
  Filename.concat (norms_dir ()) "norms.jsonl"

let ensure_dir path =
  let rec mkdir_p dir =
    if not (Sys.file_exists dir) then begin
      mkdir_p (Filename.dirname dir);
      (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
    end
  in
  mkdir_p path

(* ================================================================ *)
(* JSON                                                             *)
(* ================================================================ *)

let to_json (n : norm) : Yojson.Safe.t =
  `Assoc [
    ("id", `String n.id);
    ("pattern", `String n.pattern);
    ("occurrence_count", `Int n.occurrence_count);
    ("success_count", `Int n.success_count);
    ("success_rate", `Float n.success_rate);
    ("status", `String (string_of_status n.status));
    ("endorsers", `List (List.map (fun e -> `String e) n.endorsers));
    ("detractors", `List (List.map (fun d -> `String d) n.detractors));
    ("first_seen", `Float n.first_seen);
    ("last_seen", `Float n.last_seen);
    ("summary", `String n.summary);
  ]

let of_json (json : Yojson.Safe.t) : norm option =
  try
    let open Yojson.Safe.Util in
    Some {
      id = json |> member "id" |> to_string;
      pattern = json |> member "pattern" |> to_string;
      occurrence_count = json |> member "occurrence_count" |> to_int;
      success_count = json |> member "success_count" |> to_int;
      success_rate = json |> member "success_rate" |> to_float;
      status = json |> member "status" |> to_string |> status_of_string;
      endorsers =
        (try json |> member "endorsers" |> to_list |> List.map to_string
         with Type_error _ -> []);
      detractors =
        (try json |> member "detractors" |> to_list |> List.map to_string
         with Type_error _ -> []);
      first_seen = json |> member "first_seen" |> to_float;
      last_seen = json |> member "last_seen" |> to_float;
      summary =
        (try json |> member "summary" |> to_string
         with Type_error _ -> "");
    }
  with
  | Yojson.Safe.Util.Type_error _ -> None
  | exn ->
      Log.Norm.warn "norm of_json unexpected: %s" (Printexc.to_string exn);
      None

(* ================================================================ *)
(* File I/O                                                         *)
(* ================================================================ *)

let load_norms () : norm list =
  let path = norms_path () in
  if not (Sys.file_exists path) then []
  else begin
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let norms = ref [] in
      (try while true do
        let line = input_line ic in
        if String.length line > 0 then
          match Yojson.Safe.from_string line |> of_json with
          | Some n -> norms := n :: !norms
          | None -> ()
      done with End_of_file -> ());
      List.rev !norms)
  end

let save_norms (norms : norm list) =
  let dir = norms_dir () in
  ensure_dir dir;
  let path = norms_path () in
  let tmp = path ^ ".tmp" in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    List.iter (fun n ->
      output_string oc (Yojson.Safe.to_string (to_json n));
      output_char oc '\n'
    ) norms);
  Sys.rename tmp path

(* ================================================================ *)
(* Norm Operations                                                  *)
(* ================================================================ *)

(** Report an observed pattern (increments count, creates if new). *)
let report_pattern ~pattern ~success ~summary =
  let norms = load_norms () in
  let now = Time_compat.now () in
  let existing = List.find_opt (fun n -> n.pattern = pattern) norms in
  let updated = match existing with
    | Some n ->
      let occ = n.occurrence_count + 1 in
      let succ = n.success_count + (if success then 1 else 0) in
      let rate = Float.of_int succ /. Float.of_int occ in
      let status =
        if occ >= 5 && rate >= 0.7 && n.status = Emerging then Candidate
        else n.status
      in
      { n with
        occurrence_count = occ;
        success_count = succ;
        success_rate = rate;
        status;
        last_seen = now;
      }
    | None ->
      let id = sprintf "norm-%d-%06d" (int_of_float now) (Random.int 999999) in
      {
        id; pattern;
        occurrence_count = 1;
        success_count = (if success then 1 else 0);
        success_rate = (if success then 1.0 else 0.0);
        status = Emerging;
        endorsers = []; detractors = [];
        first_seen = now; last_seen = now;
        summary;
      }
  in
  let patched = match existing with
    | Some _ -> List.map (fun n ->
        if n.pattern = pattern then updated else n) norms
    | None -> updated :: norms
  in
  save_norms patched;
  updated

(** Agent endorses or opposes a norm. *)
let vote ~norm_id ~agent_name ~endorse =
  let norms = load_norms () in
  let patched = List.map (fun n ->
    if n.id <> norm_id then n
    else
      let endorsers, detractors =
        if endorse then
          (if List.mem agent_name n.endorsers then n.endorsers
           else agent_name :: n.endorsers),
          List.filter (fun d -> d <> agent_name) n.detractors
        else
          List.filter (fun e -> e <> agent_name) n.endorsers,
          (if List.mem agent_name n.detractors then n.detractors
           else agent_name :: n.detractors)
      in
      (* Promote to Active if 3+ distinct endorsers *)
      let distinct_endorsers = List.sort_uniq String.compare endorsers in
      let status =
        if List.length distinct_endorsers >= 3 && n.status = Candidate then Active
        else n.status
      in
      { n with endorsers; detractors; status }
  ) norms in
  save_norms patched

(** Decay: mark norms with no activity in 30 days as Fading. *)
let decay_norms () =
  let norms = load_norms () in
  let now = Time_compat.now () in
  let cutoff = now -. (30.0 *. 86400.0) in
  let patched = List.map (fun n ->
    if n.last_seen < cutoff && n.status = Active then
      { n with status = Fading }
    else if n.last_seen < cutoff -. (30.0 *. 86400.0) && n.status = Fading then
      { n with status = Retired }
    else n
  ) norms in
  save_norms patched

(** Get active norms for injection into agent context. *)
let active_norms () : norm list =
  load_norms () |> List.filter (fun n -> n.status = Active)

(** Format active norms for agent prompt injection. *)
let format_for_context () : string =
  let norms = active_norms () in
  if List.length norms = 0 then ""
  else
    let lines = List.map (fun n ->
      sprintf "- %s (endorsed by %d agents, success %.0f%%)"
        n.summary (List.length n.endorsers) (n.success_rate *. 100.0)
    ) norms in
    "[NORMS]\n" ^ String.concat "\n" lines ^ "\n[/NORMS]"
