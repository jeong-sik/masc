(** The local SearXNG container [masc prerequisite-actions searxng] starts.
    Availability says the endpoint answers a JSON search; it is distinct from a
    search finding anything, and from [runtime.toml] naming the instance. *)

type endpoint =
  | Answers
      (** [GET /search?q=...&format=json] answered 200 with a SearXNG search
          envelope: a JSON object carrying [results], [query] and
          [unresponsive_engines]. The list may be empty, and engines may be
          listed unresponsive: engines that fail make a search find nothing
          without making the endpoint unavailable. A body with none of that
          shape is another program answering on the same address. *)
  | Refuses_json
      (** The endpoint answered and does not serve SearXNG JSON: a 403 (the
          format is not enabled in settings.yml) or a body without the
          search envelope. masc asks for JSON, so this instance is of no
          use to it. *)
  | Unreachable  (** Nothing answered, or the answer was not HTTP 200. *)

type check = {
  docker : bool;  (** [docker info] succeeded: the engine is up. *)
  container : Sandbox_prerequisites.searxng_container;
      (** What [docker inspect] says about the named container. [Searxng_absent]
          when Docker is down: it cannot be asked. *)
  endpoint : endpoint;
}

val default_url : string
(** The address the container is published on, [127.0.0.1] and not
    [localhost]: a program listening on [::1] at the same port answers
    [localhost] and the container does not. A caller that points masc at the
    instance names this address. *)

val probe_max_response_bytes : int
(** Response cap for one endpoint look: 256 KiB, against a measured full
    first page of about 18 KiB (2026-10-17, 21 results). A squatter
    answering megabytes on the probed address must not fill memory per
    look. *)

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
    answers: an instance run some other way counts. Each look costs one real
    upstream search against the endpoint, capped at
    {!probe_max_response_bytes} bytes; a catalog print pays it once and a
    post-start receipt pays it per look. *)

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
    docker_status, endpoint, url}]. [status] is ["ready"] or ["unavailable"].
    [container] is one of ["absent"], ["stopped"], ["running"], ["paused"],
    ["restarting"] and ["unusable"]; [docker_status] is Docker's own word for
    ["unusable"] and null otherwise. *)
