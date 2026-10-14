(** The local SearXNG container [masc prerequisite-actions searxng] starts.
    Availability says the endpoint answers a JSON search; it is distinct from a
    search finding anything, and from [runtime.toml] naming the instance. *)

type endpoint =
  | Answers
      (** [GET /search?q=...&format=json] answered 200 with a JSON object that
          has [results]. The list may be empty: engines that fail make a
          search find nothing without making the endpoint unavailable. *)
  | Refuses_json
      (** The endpoint answered and does not serve JSON: a 403 (the format is
          not enabled in settings.yml) or a body that is not a result object.
          masc asks for JSON, so this instance is of no use to it. *)
  | Unreachable  (** Nothing answered, or the answer was not HTTP 200. *)

type check = {
  docker : bool;  (** [docker info] succeeded: the engine is up. *)
  container : Sandbox_prerequisites.searxng_container;
      (** What [docker inspect] says about the named container. [Searxng_absent]
          when Docker is down: it cannot be asked. *)
  endpoint : endpoint;
}

val default_url : string
(** The address the container publishes: the SearXNG default URL. *)

val container :
  ?run:(string list -> (string, unit) result) ->
  unit ->
  Sandbox_prerequisites.searxng_container
(** What Docker says about the named container, [Searxng_absent] when Docker
    does not answer. Cheaper than {!observe}: no HTTP. *)

val observe :
  ?run:(string list -> (string, unit) result) ->
  ?get:(string -> (int option * string, string) result) ->
  ?url:string ->
  unit ->
  check
(** One look. [run] captures a command's standard output and is [Error ()] for
    a command that did not exit 0 or did not start; [get] is an HTTP GET with
    the status. Both default to the real ones, so a test answers them. [url]
    defaults to {!default_url}. The endpoint is probed whether or not Docker
    answers: an instance run some other way counts. *)

val available : check -> bool
(** [endpoint = Answers]. *)

val wait_until_available :
  ?attempts:int ->
  ?pause_sec:float ->
  ?sleep:(float -> unit) ->
  ?run:(string list -> (string, unit) result) ->
  ?get:(string -> (int option * string, string) result) ->
  ?url:string ->
  unit ->
  check
(** {!observe} until the endpoint answers or [attempts] looks were made,
    sleeping [pause_sec] between them. A container that was just started takes
    a few seconds to listen, and a receipt that looked once would call a
    working start a failure. Returns the last look. *)

val to_json : check -> Yojson.Safe.t
(** [{schema = "masc.searxng_readiness.v1", status, docker, container,
    endpoint, url}]. [status] is ["ready"] or ["unavailable"]. *)
