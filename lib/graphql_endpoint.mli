(** Graphql_endpoint — resolve the GraphQL server URL for the
    Second Brain stack.

    Resolution order:
    - [GRAPHQL_URL] env var (operator override; localhost-style
      hosts get [http://], everything else [https://]);
    - [RAILWAY_GRAPHQL_URL] env var (always [https://]);
    - hardcoded fallback
      [https://second-brain-graphql-production.up.railway.app/graphql].

    Every resolved URL is normalised: scheme prefixed if absent,
    trailing slash trimmed, [/graphql] path appended if missing.
    Empty / whitespace-only env var values fall through to the
    next layer (rather than being treated as "disabled").

    Internal helpers (the [trim_trailing_slash] string trimmer,
    the [normalize_graphql_url] scheme/path normaliser, the
    [default_railway_url] constant, the [railway_graphql_url]
    intermediate, and the [default_scheme_for_override] localhost
    sniffer) are hidden — callers consume only the resolved URL. *)

val graphql_url : unit -> string
(** Resolve the GraphQL endpoint URL using the [GRAPHQL_URL] →
    [RAILWAY_GRAPHQL_URL] → hardcoded fallback chain documented
    above. Always returns a fully-qualified URL with a scheme
    and the [/graphql] path; never returns the empty string. *)
