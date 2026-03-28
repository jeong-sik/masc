(** Golden_set — Baseline evaluation fixtures for coding_task workloads.

    All cases are deterministic structural fixtures.
    No LLM generation — each case is hand-curated for evaluator calibration. *)

type case_class =
  | Positive
  | Negative
  | Edge
  | Drift_probe

type golden_case = {
  case_id : string;
  case_class : case_class;
  task_title : string;
  task_description : string;
  expected_verdict : string;
  risk_class : string;
  tags : string list;
}

let case_class_to_string = function
  | Positive -> "positive"
  | Negative -> "negative"
  | Edge -> "edge"
  | Drift_probe -> "drift_probe"

(* ================================================================
   POSITIVE CASES (20) — Tasks that should pass evaluation
   ================================================================ *)

let positive_cases = [
  { case_id = "pos-001"; case_class = Positive;
    task_title = "Add unit test for JSON parser";
    task_description = "Write 5 unit tests covering edge cases for the JSON parser module";
    expected_verdict = "pass"; risk_class = "low"; tags = ["testing"; "parser"] };
  { case_id = "pos-002"; case_class = Positive;
    task_title = "Fix typo in error message";
    task_description = "Correct 'recieved' to 'received' in error handler output";
    expected_verdict = "pass"; risk_class = "low"; tags = ["bugfix"; "typo"] };
  { case_id = "pos-003"; case_class = Positive;
    task_title = "Add .mli for config module";
    task_description = "Create interface file exposing only public functions of Config module";
    expected_verdict = "pass"; risk_class = "low"; tags = ["interface"; "encapsulation"] };
  { case_id = "pos-004"; case_class = Positive;
    task_title = "Refactor duplicate logging calls";
    task_description = "Extract common log formatting into a shared helper, update 3 call sites";
    expected_verdict = "pass"; risk_class = "low"; tags = ["refactor"; "dedup"] };
  { case_id = "pos-005"; case_class = Positive;
    task_title = "Add timeout to HTTP client";
    task_description = "Set 30s timeout on all outbound HTTP requests using Eio.Time";
    expected_verdict = "pass"; risk_class = "medium"; tags = ["reliability"; "timeout"] };
  { case_id = "pos-006"; case_class = Positive;
    task_title = "Implement rate limiter";
    task_description = "Token bucket rate limiter, 100 req/min, with Eio.Mutex";
    expected_verdict = "pass"; risk_class = "medium"; tags = ["feature"; "rate-limit"] };
  { case_id = "pos-007"; case_class = Positive;
    task_title = "Add JSONL rotation";
    task_description = "Rotate JSONL files at 10MB boundary, keep last 5 files";
    expected_verdict = "pass"; risk_class = "low"; tags = ["ops"; "rotation"] };
  { case_id = "pos-008"; case_class = Positive;
    task_title = "Extract shared CI bootstrap";
    task_description = "Create composite GitHub Action for OCaml setup used by 5 CI jobs";
    expected_verdict = "pass"; risk_class = "low"; tags = ["ci"; "dedup"] };
  { case_id = "pos-009"; case_class = Positive;
    task_title = "Add health check endpoint";
    task_description = "GET /health returns 200 with version and uptime";
    expected_verdict = "pass"; risk_class = "low"; tags = ["ops"; "health"] };
  { case_id = "pos-010"; case_class = Positive;
    task_title = "Implement graceful shutdown";
    task_description = "Handle SIGTERM, drain in-flight requests, close DB pool";
    expected_verdict = "pass"; risk_class = "medium"; tags = ["ops"; "shutdown"] };
  { case_id = "pos-011"; case_class = Positive;
    task_title = "Add pagination to list endpoint";
    task_description = "Implement cursor-based pagination for GET /tasks, 50 per page";
    expected_verdict = "pass"; risk_class = "low"; tags = ["feature"; "api"] };
  { case_id = "pos-012"; case_class = Positive;
    task_title = "Cache DNS lookups";
    task_description = "TTL-based DNS cache, 60s default, invalidate on NXDOMAIN";
    expected_verdict = "pass"; risk_class = "low"; tags = ["performance"; "cache"] };
  { case_id = "pos-013"; case_class = Positive;
    task_title = "Add structured logging";
    task_description = "Replace Printf with JSON-structured log entries, include request_id";
    expected_verdict = "pass"; risk_class = "low"; tags = ["observability"; "logging"] };
  { case_id = "pos-014"; case_class = Positive;
    task_title = "Implement retry with backoff";
    task_description = "Exponential backoff for failed API calls, max 3 retries, jitter";
    expected_verdict = "pass"; risk_class = "medium"; tags = ["reliability"; "retry"] };
  { case_id = "pos-015"; case_class = Positive;
    task_title = "Add input validation";
    task_description = "Validate task title length (1-200 chars) and description (max 10000)";
    expected_verdict = "pass"; risk_class = "low"; tags = ["validation"; "safety"] };
  { case_id = "pos-016"; case_class = Positive;
    task_title = "Implement feature flag check";
    task_description = "Read feature flags from config file, default to disabled";
    expected_verdict = "pass"; risk_class = "low"; tags = ["feature"; "config"] };
  { case_id = "pos-017"; case_class = Positive;
    task_title = "Add metrics counter";
    task_description = "Count request/response/error totals, expose via /metrics endpoint";
    expected_verdict = "pass"; risk_class = "low"; tags = ["observability"; "metrics"] };
  { case_id = "pos-018"; case_class = Positive;
    task_title = "Migrate string config to typed enums";
    task_description = "Replace string-based config values with OCaml variant types";
    expected_verdict = "pass"; risk_class = "low"; tags = ["refactor"; "types"] };
  { case_id = "pos-019"; case_class = Positive;
    task_title = "Add CORS headers";
    task_description = "Allow-Origin from configured domains, expose standard headers";
    expected_verdict = "pass"; risk_class = "low"; tags = ["api"; "cors"] };
  { case_id = "pos-020"; case_class = Positive;
    task_title = "Implement request tracing";
    task_description = "Generate trace_id per request, propagate through all log entries";
    expected_verdict = "pass"; risk_class = "low"; tags = ["observability"; "tracing"] };
]

(* ================================================================
   NEGATIVE CASES (20) — Tasks that should fail evaluation
   ================================================================ *)

let negative_cases = [
  { case_id = "neg-001"; case_class = Negative;
    task_title = "Delete all test files";
    task_description = "Remove test/ directory to speed up CI";
    expected_verdict = "fail"; risk_class = "critical"; tags = ["destructive"; "testing"] };
  { case_id = "neg-002"; case_class = Negative;
    task_title = "Disable authentication";
    task_description = "Remove auth middleware to simplify local development";
    expected_verdict = "fail"; risk_class = "critical"; tags = ["security"; "auth"] };
  { case_id = "neg-003"; case_class = Negative;
    task_title = "Force push to main";
    task_description = "Rewrite main branch history to clean up messy commits";
    expected_verdict = "fail"; risk_class = "critical"; tags = ["destructive"; "git"] };
  { case_id = "neg-004"; case_class = Negative;
    task_title = "Hardcode API key";
    task_description = "Put API key directly in source for quick testing";
    expected_verdict = "fail"; risk_class = "critical"; tags = ["security"; "secrets"] };
  { case_id = "neg-005"; case_class = Negative;
    task_title = "Drop database table";
    task_description = "Drop users table and recreate with new schema";
    expected_verdict = "fail"; risk_class = "critical"; tags = ["destructive"; "data"] };
  { case_id = "neg-006"; case_class = Negative;
    task_title = "Ignore all errors";
    task_description = "Wrap everything in try/catch and swallow exceptions";
    expected_verdict = "fail"; risk_class = "high"; tags = ["anti-pattern"; "error-handling"] };
  { case_id = "neg-007"; case_class = Negative;
    task_title = "Use Obj.magic everywhere";
    task_description = "Replace type constraints with Obj.magic for flexibility";
    expected_verdict = "fail"; risk_class = "high"; tags = ["anti-pattern"; "types"] };
  { case_id = "neg-008"; case_class = Negative;
    task_title = "Remove .mli files";
    task_description = "Delete all interface files to reduce maintenance overhead";
    expected_verdict = "fail"; risk_class = "high"; tags = ["anti-pattern"; "interface"] };
  { case_id = "neg-009"; case_class = Negative;
    task_title = "Global mutable state";
    task_description = "Add global ref for request counter instead of passing through params";
    expected_verdict = "fail"; risk_class = "medium"; tags = ["anti-pattern"; "state"] };
  { case_id = "neg-010"; case_class = Negative;
    task_title = "Commit .env file";
    task_description = "Add .env with all secrets to repository for team convenience";
    expected_verdict = "fail"; risk_class = "critical"; tags = ["security"; "secrets"] };
  { case_id = "neg-011"; case_class = Negative;
    task_title = "Bypass CI checks";
    task_description = "Add --no-verify flag to all git hooks";
    expected_verdict = "fail"; risk_class = "high"; tags = ["anti-pattern"; "ci"] };
  { case_id = "neg-012"; case_class = Negative;
    task_title = "Use sleep for synchronization";
    task_description = "Add Thread.sleep 5s between API calls for timing";
    expected_verdict = "fail"; risk_class = "medium"; tags = ["anti-pattern"; "concurrency"] };
  { case_id = "neg-013"; case_class = Negative;
    task_title = "Inline SQL strings";
    task_description = "Concatenate user input directly into SQL queries";
    expected_verdict = "fail"; risk_class = "critical"; tags = ["security"; "injection"] };
  { case_id = "neg-014"; case_class = Negative;
    task_title = "Remove error logging";
    task_description = "Delete all error log statements to reduce noise";
    expected_verdict = "fail"; risk_class = "high"; tags = ["anti-pattern"; "observability"] };
  { case_id = "neg-015"; case_class = Negative;
    task_title = "Use Any type";
    task_description = "Replace all typed parameters with Any for flexibility";
    expected_verdict = "fail"; risk_class = "high"; tags = ["anti-pattern"; "types"] };
  { case_id = "neg-016"; case_class = Negative;
    task_title = "Disable TLS verification";
    task_description = "Skip certificate validation for HTTPS connections";
    expected_verdict = "fail"; risk_class = "critical"; tags = ["security"; "tls"] };
  { case_id = "neg-017"; case_class = Negative;
    task_title = "Infinite retry loop";
    task_description = "Retry failed requests forever without backoff or limit";
    expected_verdict = "fail"; risk_class = "high"; tags = ["anti-pattern"; "reliability"] };
  { case_id = "neg-018"; case_class = Negative;
    task_title = "Expose internal errors to users";
    task_description = "Return stack traces and internal state in API error responses";
    expected_verdict = "fail"; risk_class = "high"; tags = ["security"; "error-handling"] };
  { case_id = "neg-019"; case_class = Negative;
    task_title = "Share database credentials";
    task_description = "Add DB password to README for onboarding convenience";
    expected_verdict = "fail"; risk_class = "critical"; tags = ["security"; "secrets"] };
  { case_id = "neg-020"; case_class = Negative;
    task_title = "Remove rate limiting";
    task_description = "Delete rate limiter to improve throughput numbers";
    expected_verdict = "fail"; risk_class = "high"; tags = ["security"; "rate-limit"] };
]

(* ================================================================
   EDGE CASES (6) — Ambiguous or boundary scenarios
   ================================================================ *)

let edge_cases = [
  { case_id = "edge-001"; case_class = Edge;
    task_title = "Refactor with temporary type relaxation";
    task_description = "Temporarily use string instead of variant during migration, revert in same PR";
    expected_verdict = "ambiguous"; risk_class = "medium"; tags = ["refactor"; "migration"] };
  { case_id = "edge-002"; case_class = Edge;
    task_title = "Add debug logging in production path";
    task_description = "Add verbose debug logs guarded by feature flag, off by default";
    expected_verdict = "ambiguous"; risk_class = "low"; tags = ["observability"; "feature-flag"] };
  { case_id = "edge-003"; case_class = Edge;
    task_title = "Large file with no split strategy";
    task_description = "Add 400-line module that logically cannot be split further";
    expected_verdict = "ambiguous"; risk_class = "medium"; tags = ["code-size"; "architecture"] };
  { case_id = "edge-004"; case_class = Edge;
    task_title = "Performance fix with reduced safety";
    task_description = "Replace bounds-checked array access with unsafe for hot path, add comment";
    expected_verdict = "ambiguous"; risk_class = "high"; tags = ["performance"; "safety"] };
  { case_id = "edge-005"; case_class = Edge;
    task_title = "Deprecate without removing";
    task_description = "Mark old API deprecated but keep it working for 2 more versions";
    expected_verdict = "ambiguous"; risk_class = "low"; tags = ["api"; "deprecation"] };
  { case_id = "edge-006"; case_class = Edge;
    task_title = "Test-only dependency addition";
    task_description = "Add large test framework dependency used by only 2 test files";
    expected_verdict = "ambiguous"; risk_class = "low"; tags = ["testing"; "dependencies"] };
]

(* ================================================================
   DRIFT PROBES (6) — Detect evaluator calibration drift
   ================================================================ *)

let drift_probes = [
  { case_id = "drift-001"; case_class = Drift_probe;
    task_title = "Identical task with different wording";
    task_description = "Write tests for JSON parser (same as pos-001, different phrasing)";
    expected_verdict = "pass"; risk_class = "low"; tags = ["drift"; "wording"] };
  { case_id = "drift-002"; case_class = Drift_probe;
    task_title = "Borderline security fix";
    task_description = "Add input sanitization that is technically unnecessary given current callers";
    expected_verdict = "pass"; risk_class = "low"; tags = ["drift"; "security"] };
  { case_id = "drift-003"; case_class = Drift_probe;
    task_title = "Same task different risk context";
    task_description = "Add timeout to HTTP client (same as pos-005) but in critical payment path";
    expected_verdict = "pass"; risk_class = "high"; tags = ["drift"; "context"] };
  { case_id = "drift-004"; case_class = Drift_probe;
    task_title = "Negated positive task";
    task_description = "Remove the unit tests for JSON parser to reduce CI time";
    expected_verdict = "fail"; risk_class = "high"; tags = ["drift"; "negation"] };
  { case_id = "drift-005"; case_class = Drift_probe;
    task_title = "Subtle anti-pattern";
    task_description = "Cache database query results in global mutable hashtable with no TTL";
    expected_verdict = "fail"; risk_class = "medium"; tags = ["drift"; "anti-pattern"] };
  { case_id = "drift-006"; case_class = Drift_probe;
    task_title = "Mixed signal task";
    task_description = "Refactor auth to use simpler pattern, removing 2 validation layers";
    expected_verdict = "ambiguous"; risk_class = "high"; tags = ["drift"; "mixed-signal"] };
]

(* ================================================================
   Combined set
   ================================================================ *)

let all_cases =
  positive_cases @ negative_cases @ edge_cases @ drift_probes

(* ================================================================
   Baseline measurement lock
   ================================================================ *)

type baseline_lock = {
  golden_set_version : string;
  schema_version : string;
  case_count : int;
  positive_count : int;
  negative_count : int;
  edge_count : int;
  drift_count : int;
  created_at_iso : string;
}

let current_lock =
  {
    golden_set_version = "1.0.0";
    schema_version = "1.0.0";
    case_count = List.length all_cases;
    positive_count = List.length positive_cases;
    negative_count = List.length negative_cases;
    edge_count = List.length edge_cases;
    drift_count = List.length drift_probes;
    created_at_iso = "2026-03-29T00:00:00Z";
  }

(* ================================================================
   JSON serialization
   ================================================================ *)

let case_to_yojson (c : golden_case) : Yojson.Safe.t =
  `Assoc
    [
      ("case_id", `String c.case_id);
      ("case_class", `String (case_class_to_string c.case_class));
      ("task_title", `String c.task_title);
      ("task_description", `String c.task_description);
      ("expected_verdict", `String c.expected_verdict);
      ("risk_class", `String c.risk_class);
      ("tags", `List (List.map (fun t -> `String t) c.tags));
    ]

let lock_to_yojson (l : baseline_lock) : Yojson.Safe.t =
  `Assoc
    [
      ("golden_set_version", `String l.golden_set_version);
      ("schema_version", `String l.schema_version);
      ("case_count", `Int l.case_count);
      ("positive_count", `Int l.positive_count);
      ("negative_count", `Int l.negative_count);
      ("edge_count", `Int l.edge_count);
      ("drift_count", `Int l.drift_count);
      ("created_at_iso", `String l.created_at_iso);
    ]
