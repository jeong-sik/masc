type full
type partial
type graceful

type ('a, 'e) t =
  | FullSuccess : {
      value : 'a;
      confidence : Confidence.t;
      artifacts : Artifact_id.t list;
    } -> ('a, 'e) t
  | PartialSuccess : {
      value : 'a;
      completed : Artifact_id.t list;
      failed : (Artifact_id.t * 'e) list;
      confidence : Confidence.t;
      degradation_level : int;
    } -> ('a, 'e) t
  | GracefulFailure : {
      fallback : 'a option;
      reason : string;
      recovery_strategy : string;
      confidence : Confidence.t;
    } -> ('a, 'e) t

let clamp_level n =
  if n < 1 then 1
  else if n > 4 then 4
  else n

let full ~value ~confidence ~artifacts =
  FullSuccess { value; confidence; artifacts }

let partial ~value ~completed ~failed ~confidence ~degradation_level =
  PartialSuccess
    { value;
      completed;
      failed;
      confidence;
      degradation_level = clamp_level degradation_level;
    }

let graceful ?fallback ~reason ~recovery_strategy ~confidence () =
  GracefulFailure { fallback; reason; recovery_strategy; confidence }

let is_full : type a e. (a, e) t -> bool = function
  | FullSuccess _ -> true
  | PartialSuccess _ | GracefulFailure _ -> false

let is_partial : type a e. (a, e) t -> bool = function
  | PartialSuccess _ -> true
  | FullSuccess _ | GracefulFailure _ -> false

let is_graceful : type a e. (a, e) t -> bool = function
  | GracefulFailure _ -> true
  | FullSuccess _ | PartialSuccess _ -> false

let value_opt : type a e. (a, e) t -> a option = function
  | FullSuccess { value; _ } -> Some value
  | PartialSuccess { value; _ } -> Some value
  | GracefulFailure { fallback; _ } -> fallback

let confidence : type a e. (a, e) t -> Confidence.t = function
  | FullSuccess { confidence; _ } -> confidence
  | PartialSuccess { confidence; _ } -> confidence
  | GracefulFailure { confidence; _ } -> confidence

let map : type a b e. (a -> b) -> (a, e) t -> (b, e) t =
  fun f -> function
  | FullSuccess { value; confidence; artifacts } ->
    FullSuccess { value = f value; confidence; artifacts }
  | PartialSuccess { value; completed; failed; confidence; degradation_level } ->
    PartialSuccess
      { value = f value;
        completed;
        failed;
        confidence;
        degradation_level;
      }
  | GracefulFailure { fallback; reason; recovery_strategy; confidence } ->
    GracefulFailure
      { fallback = Option.map f fallback;
        reason;
        recovery_strategy;
        confidence;
      }

let cata :
  type a e r.
  full:(a -> Confidence.t -> Artifact_id.t list -> r) ->
  partial:(a -> Artifact_id.t list -> (Artifact_id.t * e) list ->
           Confidence.t -> int -> r) ->
  graceful:(a option -> string -> string -> Confidence.t -> r) ->
  (a, e) t -> r =
  fun ~full ~partial ~graceful t ->
  match t with
  | FullSuccess { value; confidence; artifacts } ->
    full value confidence artifacts
  | PartialSuccess { value; completed; failed; confidence; degradation_level } ->
    partial value completed failed confidence degradation_level
  | GracefulFailure { fallback; reason; recovery_strategy; confidence } ->
    graceful fallback reason recovery_strategy confidence

let lift_result ?confidence ?(artifacts = []) = function
  | Ok value ->
    let c = Option.value confidence ~default:Confidence.one in
    FullSuccess { value; confidence = c; artifacts }
  | Error _ ->
    GracefulFailure
      { fallback = None;
        reason = "lifted from Error";
        recovery_strategy = "Abort";
        confidence = Confidence.zero;
      }

let class_to_string : type a e. (a, e) t -> string = function
  | FullSuccess _ -> "FullSuccess"
  | PartialSuccess _ -> "PartialSuccess"
  | GracefulFailure _ -> "GracefulFailure"
