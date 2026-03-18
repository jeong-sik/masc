(** Chain Category - Category Theory Abstractions for Chain Engine

    결합(Composition)과 분해(Decomposition)의 수학적 기반을 제공합니다.

    핵심 법칙:
    - 항등원: id >> f = f = f >> id
    - 결합법칙: (a >> b) >> c = a >> (b >> c)
    - 함자 법칙: map id = id, map (f . g) = map f . map g

    @author Chain Engine
    @since 2026-01
*)

(** {1 Core Signatures} *)

(** Functor - 분해: 컨테이너 내부 값 변환

    Functor는 컨테이너 내부의 값을 변환하는 추상화입니다.
    노드 출력을 다른 타입으로 변환할 때 사용합니다. *)
module type FUNCTOR = sig
  type 'a t

  (** [map f x] applies [f] to the value inside [x].
      Laws:
      - map id = id
      - map (f . g) = map f . map g *)
  val map : ('a -> 'b) -> 'a t -> 'b t
end

(** Applicative - 결합: 독립적 효과의 병렬 적용

    Applicative는 독립적인 계산을 병렬로 조합하는 추상화입니다.
    Fanout 패턴(독립적인 노드들의 병렬 실행)에 사용됩니다. *)
module type APPLICATIVE = sig
  include FUNCTOR

  (** [pure x] lifts [x] into the applicative context. *)
  val pure : 'a -> 'a t

  (** [ap f x] applies the function inside [f] to the value inside [x].
      This enables parallel composition of independent computations. *)
  val ap : ('a -> 'b) t -> 'a t -> 'b t

  (** [map2 f x y] combines two applicatives with a binary function. *)
  val map2 : ('a -> 'b -> 'c) -> 'a t -> 'b t -> 'c t

  (** [sequence xs] collects a list of applicatives into an applicative of list.
      Enables parallel execution of independent operations. *)
  val sequence : 'a t list -> 'a list t
end

(** Monad - 결합: 순차 의존성 체인

    Monad는 순차적 의존성을 가진 계산을 조합하는 추상화입니다.
    Pipeline 패턴(이전 노드 결과에 의존하는 순차 실행)에 사용됩니다. *)
module type MONAD = sig
  include APPLICATIVE

  (** [bind m f] sequences [m] with [f], where [f] depends on [m]'s result.
      Also known as flatMap or >>=.
      Laws:
      - bind (pure x) f = f x         (left identity)
      - bind m pure = m                (right identity)
      - bind (bind m f) g = bind m (fun x -> bind (f x) g)  (associativity) *)
  val bind : 'a t -> ('a -> 'b t) -> 'b t

  (** Infix bind operator. *)
  val ( >>= ) : 'a t -> ('a -> 'b t) -> 'b t

  (** [join mm] flattens a nested monad. *)
  val join : 'a t t -> 'a t

  (** Kleisli composition: [(f >=> g) x = f x >>= g].
      Composes two monadic functions. *)
  val ( >=> ) : ('a -> 'b t) -> ('b -> 'c t) -> ('a -> 'c t)
end

(** Monoid - 결합: 결과 합치기

    Monoid는 값들을 합치는 추상화입니다.
    Merge 패턴(여러 노드 결과를 하나로 합치기)에 사용됩니다. *)
module type MONOID = sig
  type t

  (** The identity element. [concat empty x = x = concat x empty] *)
  val empty : t

  (** [concat a b] combines two values.
      Must be associative: concat (concat a b) c = concat a (concat b c) *)
  val concat : t -> t -> t

  (** [concat_all xs] combines a list of values left-to-right. *)
  val concat_all : t list -> t
end

(** Kleisli Arrow - 결합: 파이프라인 조립

    Kleisli Arrow는 실패 가능한 계산을 조합하는 추상화입니다.
    에러 핸들링이 포함된 파이프라인 구성에 사용됩니다. *)
module type KLEISLI = sig
  type ('a, 'b) t

  (** [arr f] lifts a pure function into an arrow. *)
  val arr : ('a -> 'b) -> ('a, 'b) t

  (** [f >>> g] composes two arrows sequentially. *)
  val ( >>> ) : ('a, 'b) t -> ('b, 'c) t -> ('a, 'c) t

  (** [f &&& g] runs both arrows on the same input (fanout). *)
  val ( &&& ) : ('a, 'b) t -> ('a, 'c) t -> ('a, 'b * 'c) t

  (** [f *** g] runs arrows on respective inputs (parallel). *)
  val ( *** ) : ('a, 'b) t -> ('c, 'd) t -> ('a * 'c, 'b * 'd) t

  (** [first f] runs [f] on the first element of a pair. *)
  val first : ('a, 'b) t -> ('a * 'c, 'b * 'c) t

  (** [second f] runs [f] on the second element of a pair. *)
  val second : ('a, 'b) t -> ('c * 'a, 'c * 'b) t
end

(** Profunctor - 분해+결합: 입출력 양방향 변환

    Profunctor는 입력과 출력을 동시에 변환하는 추상화입니다.
    Adapter 노드(입출력 타입 변환)에 사용됩니다. *)
module type PROFUNCTOR = sig
  type ('a, 'b) t

  (** [dimap f g p] transforms both input (contravariantly) and output (covariantly).
      [dimap f g p = lmap f (rmap g p) = rmap g (lmap f p)] *)
  val dimap : ('a -> 'b) -> ('c -> 'd) -> ('b, 'c) t -> ('a, 'd) t

  (** [lmap f p] transforms the input. *)
  val lmap : ('a -> 'b) -> ('b, 'c) t -> ('a, 'c) t

  (** [rmap f p] transforms the output. *)
  val rmap : ('b -> 'c) -> ('a, 'b) t -> ('a, 'c) t
end

(** {1 Result-based Implementations} *)

(** Result monad for error-handling chains *)
module Result_monad : sig
  include MONAD with type 'a t = ('a, string) result

  (** [run m] extracts the result or raises Failure. *)
  val run : 'a t -> 'a

  (** [catch f] catches exceptions and wraps them in Error. *)
  val catch : (unit -> 'a) -> 'a t

  (** [map_error f m] transforms the error case. *)
  val map_error : (string -> string) -> 'a t -> 'a t
end

(** {1 Kleisli Arrow for Result} *)

(** Kleisli arrows over Result - composable error-handling pipelines *)
module Result_kleisli : sig
  include KLEISLI with type ('a, 'b) t = 'a -> ('b, string) result

  (** [run f x] executes the arrow on input [x]. *)
  val run : ('a, 'b) t -> 'a -> ('b, string) result

  (** [from_option ~error f] converts an option-returning function. *)
  val from_option : error:string -> ('a -> 'b option) -> ('a, 'b) t

  (** [guard ~error pred] fails if predicate is false. *)
  val guard : error:string -> ('a -> bool) -> ('a, 'a) t

  (** [retry ~times ~delay f] retries on failure. *)
  val retry : times:int -> delay:float -> ('a, 'b) t -> ('a, 'b) t
end

(** {1 Practical Monoid Instances} *)

(** Verdict type from validator *)
type verdict =
  | Pass of string  (** Validation passed with message *)
  | Warn of string  (** Validation passed with warning *)
  | Fail of string  (** Validation failed with reason *)
  | Defer of string (** Validation deferred *)

val verdict_to_yojson : verdict -> Yojson.Safe.t
val verdict_of_yojson : Yojson.Safe.t -> (verdict, string) result

(** Verdict monoid - combines verdicts with fail-fast semantics *)
module Verdict_monoid : MONOID with type t = verdict

(** Confidence monoid - combines confidence scores *)
module Confidence_monoid : sig
  include MONOID with type t = float

  (** [geometric xs] computes geometric mean (for multiplicative confidence). *)
  val geometric : float list -> float

  (** [harmonic xs] computes harmonic mean (penalizes low scores). *)
  val harmonic : float list -> float

  (** [weighted ws xs] computes weighted average. *)
  val weighted : float list -> float list -> float
end

(** Trace monoid - accumulates execution traces *)
module Trace_monoid : MONOID with type t = (string * float) list

(** Token usage type *)
type token_usage = {
  prompt_tokens: int;
  completion_tokens: int;
  total_tokens: int;
  estimated_cost_usd: float;
}

val token_usage_to_yojson : token_usage -> Yojson.Safe.t
val token_usage_of_yojson : Yojson.Safe.t -> (token_usage, string) result

(** Token usage monoid - sums token counts *)
module Token_monoid : MONOID with type t = token_usage

(** {1 Profunctor for Adapters} *)

(** Function profunctor - input/output adapters *)
module Function_profunctor : PROFUNCTOR with type ('a, 'b) t = 'a -> 'b

(** {1 Utility Functions} *)

(** [identity] is the identity function. *)
val identity : 'a -> 'a

(** [compose f g] is function composition: (f . g) x = f (g x). *)
val compose : ('b -> 'c) -> ('a -> 'b) -> 'a -> 'c

(** Infix function composition. *)
val ( << ) : ('b -> 'c) -> ('a -> 'b) -> 'a -> 'c

(** Reverse function composition: (f >> g) x = g (f x). *)
val ( >> ) : ('a -> 'b) -> ('b -> 'c) -> 'a -> 'c

(** [flip f] swaps the arguments of a binary function. *)
val flip : ('a -> 'b -> 'c) -> 'b -> 'a -> 'c

(** [const x] returns a function that always returns [x]. *)
val const : 'a -> 'b -> 'a

(** [curry f] converts a function on pairs to a curried function. *)
val curry : ('a * 'b -> 'c) -> 'a -> 'b -> 'c

(** [uncurry f] converts a curried function to a function on pairs. *)
val uncurry : ('a -> 'b -> 'c) -> 'a * 'b -> 'c

(** {1 Laws Verification (for testing)} *)

(** Laws module provides functions to verify category theory laws *)
module Laws : sig
  (** Functor laws verification *)
  module Functor (F : FUNCTOR) : sig
    val identity_law : 'a F.t -> ('a F.t -> 'a F.t -> bool) -> bool
    val composition_law : ('b -> 'c) -> ('a -> 'b) -> 'a F.t -> ('c F.t -> 'c F.t -> bool) -> bool
  end

  (** Monad laws verification *)
  module Monad (M : MONAD) : sig
    val left_identity_law : 'a -> ('a -> 'b M.t) -> ('b M.t -> 'b M.t -> bool) -> bool
    val right_identity_law : 'a M.t -> ('a M.t -> 'a M.t -> bool) -> bool
    val associativity_law : 'a M.t -> ('a -> 'b M.t) -> ('b -> 'c M.t) -> ('c M.t -> 'c M.t -> bool) -> bool
  end

  (** Monoid laws verification *)
  module Monoid (Mon : MONOID) : sig
    val left_identity_law : Mon.t -> bool
    val right_identity_law : Mon.t -> bool
    val associativity_law : Mon.t -> Mon.t -> Mon.t -> bool
  end
end
