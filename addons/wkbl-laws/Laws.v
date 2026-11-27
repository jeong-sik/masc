(** Conservation laws of one basketball box score, a checker for them, and
    proofs that the checker reports exactly the failures of those laws.

    Rocq checks every statement in this file. It does not check driver.ml,
    which reads the input text, or server.py around it; the shared fixtures
    under fixtures/ pin that boundary from both sides. *)

From Coq Require Import List NArith Bool Lia Setoid.
Import ListNotations.

Section Laws.

Variables team player label : Type.
Variable team_eqb : team -> team -> bool.
Variable player_eqb : player -> player -> bool.
Hypothesis team_eqb_spec : forall a b, reflect (a = b) (team_eqb a b).
Hypothesis player_eqb_spec : forall a b, reflect (a = b) (player_eqb a b).

(** One box-score row. [line_player] is [None] when the store has no player
    number for the row. Such a row still counts toward its team's points but
    takes no part in the one-row-per-player law. [line_label] names the row
    for the report; the checker never inspects it. *)
Record line := {
  line_label : label;
  line_team : team;
  line_player : option player;
  points : N;
  two_made : N;
  three_made : N;
  free_made : N }.

(** One team of one game as the result table records it. [None] means the
    table holds no value, and a law that needs the value does not apply. *)
Record side := {
  side_team : team;
  final : option N;
  quarters : option (list N) }.

Record game := { home : side; away : side; lines : list line }.

Inductive violation :=
| Box_points_differ (t : team) (stated box : N)
| Quarter_points_differ (t : team) (stated quarter_total : N)
| Composition_differs (l : label) (stated composed : N)
| Foreign_team (l : label) (t : team)
| Repeated_player (l : label) (p : player).

Definition total (xs : list N) : N := fold_right N.add 0%N xs.

Definition composed (l : line) : N :=
  (2 * two_made l + 3 * three_made l + free_made l)%N.

Definition team_lines (g : game) (t : team) : list line :=
  filter (fun l => team_eqb (line_team l) t) (lines g).

(** A side has a box-score total only when the box score has a row for it. *)
Definition box_points (g : game) (s : side) : option N :=
  match team_lines g (side_team s) with
  | [] => None
  | ls => Some (total (map points ls))
  end.

Definition quarter_points (s : side) : option N := option_map total (quarters s).

Definition player_of (l : line) : list player :=
  match line_player l with Some p => [p] | None => [] end.

Definition known_players (ls : list line) : list player := flat_map player_of ls.

(** * The laws *)

Definition agree (a b : option N) : Prop :=
  match a, b with
  | Some x, Some y => x = y
  | _, _ => True
  end.

(** The final score equals the sum of the players' points and the sum of
    the quarter points, wherever those are recorded. *)
Definition side_laws (g : game) (s : side) : Prop :=
  agree (final s) (box_points g s) /\ agree (final s) (quarter_points s).

Definition in_game (g : game) (t : team) : Prop :=
  t = side_team (home g) \/ t = side_team (away g).

(** A row's points are two per two-point basket, three per three-point
    basket and one per free throw, and the row belongs to one of the game's
    two teams. *)
Definition line_laws (g : game) (l : line) : Prop :=
  points l = composed l /\ in_game g (line_team l).

(** Every law of one game: both sides' totals, every row, and no player
    number on two rows. *)
Definition game_laws (g : game) : Prop :=
  side_laws g (home g) /\ side_laws g (away g) /\
  Forall (line_laws g) (lines g) /\ NoDup (known_players (lines g)).

(** * The checker *)

Definition differ (make : N -> N -> violation) (a b : option N) : list violation :=
  match a, b with
  | Some x, Some y => if N.eqb x y then [] else [make x y]
  | _, _ => []
  end.

Definition side_violations (g : game) (s : side) : list violation :=
  differ (Box_points_differ (side_team s)) (final s) (box_points g s) ++
  differ (Quarter_points_differ (side_team s)) (final s) (quarter_points s).

Definition in_gameb (g : game) (t : team) : bool :=
  team_eqb t (side_team (home g)) || team_eqb t (side_team (away g)).

Definition line_violations (g : game) (l : line) : list violation :=
  (if N.eqb (points l) (composed l) then []
   else [Composition_differs (line_label l) (points l) (composed l)]) ++
  (if in_gameb g (line_team l) then []
   else [Foreign_team (line_label l) (line_team l)]).

Definition same_player (p : player) (l : line) : bool :=
  match line_player l with Some q => player_eqb p q | None => false end.

(** A row is reported when a later row of the same game has its player. *)
Fixpoint repeated (ls : list line) : list violation :=
  match ls with
  | [] => []
  | l :: rest =>
      match line_player l with
      | Some p =>
          if existsb (same_player p) rest
          then [Repeated_player (line_label l) p] else []
      | None => []
      end ++ repeated rest
  end.

Definition check (g : game) : list violation :=
  side_violations g (home g) ++ side_violations g (away g) ++
  flat_map (line_violations g) (lines g) ++ repeated (lines g).

(** What each report claims about the game. *)
Definition fails (g : game) (v : violation) : Prop :=
  match v with
  | Box_points_differ t x y =>
      exists s, (s = home g \/ s = away g) /\ side_team s = t /\
        final s = Some x /\ box_points g s = Some y /\ x <> y
  | Quarter_points_differ t x y =>
      exists s, (s = home g \/ s = away g) /\ side_team s = t /\
        final s = Some x /\ quarter_points s = Some y /\ x <> y
  | Composition_differs lb x y =>
      exists l, In l (lines g) /\ line_label l = lb /\
        points l = x /\ composed l = y /\ x <> y
  | Foreign_team lb t =>
      exists l, In l (lines g) /\ line_label l = lb /\
        line_team l = t /\ ~ in_game g t
  | Repeated_player lb p =>
      exists before l after, lines g = before ++ l :: after /\
        line_label l = lb /\ line_player l = Some p /\ In p (known_players after)
  end.

(** * Proofs *)

Lemma app_nil_iff {A} (xs ys : list A) : xs ++ ys = [] <-> xs = [] /\ ys = [].
Proof. destruct xs, ys; simpl; intuition congruence. Qed.

Lemma flat_map_nil_iff {A B} (f : A -> list B) (xs : list A) :
  flat_map f xs = [] <-> Forall (fun x => f x = []) xs.
Proof.
  induction xs as [|x xs IH]; simpl.
  - split; intros; [constructor | reflexivity].
  - rewrite app_nil_iff, IH. split.
    + intros [Hx Hxs]. constructor; assumption.
    + intros H. inversion H; subst. split; assumption.
Qed.

Lemma known_players_cons l ls :
  known_players (l :: ls) = player_of l ++ known_players ls.
Proof. reflexivity. Qed.

Lemma NoDup_app_r {A} (xs ys : list A) : NoDup (xs ++ ys) -> NoDup ys.
Proof.
  induction xs as [|x xs IH]; simpl; intros H; [assumption|].
  apply IH. apply NoDup_cons_iff in H. tauto.
Qed.

Lemma differ_nil make a b : differ make a b = [] <-> agree a b.
Proof.
  destruct a as [x|], b as [y|]; simpl; try (split; auto; fail).
  destruct (N.eqb_spec x y); split; congruence.
Qed.

Lemma in_differ make a b v :
  In v (differ make a b) <->
  exists x y, a = Some x /\ b = Some y /\ x <> y /\ v = make x y.
Proof.
  destruct a as [x|], b as [y|]; simpl.
  - destruct (N.eqb_spec x y) as [Heq|Hne]; simpl.
    + split; [tauto|]. intros (x' & y' & Hx & Hy & Hne & _). congruence.
    + split.
      * intros [Hv|[]]. exists x, y. repeat split; auto; congruence.
      * intros (x' & y' & Hx & Hy & _ & Hv). left. congruence.
  - split; [tauto|]. intros (x' & y' & _ & Hy & _). discriminate.
  - split; [tauto|]. intros (x' & y' & Hx & _). discriminate.
  - split; [tauto|]. intros (x' & y' & Hx & _). discriminate.
Qed.

Lemma side_violations_nil g s : side_violations g s = [] <-> side_laws g s.
Proof.
  unfold side_violations, side_laws. rewrite app_nil_iff, !differ_nil. reflexivity.
Qed.

Lemma in_side_violations g s v :
  In v (side_violations g s) <->
  (exists x y, final s = Some x /\ box_points g s = Some y /\ x <> y /\
     v = Box_points_differ (side_team s) x y) \/
  (exists x y, final s = Some x /\ quarter_points s = Some y /\ x <> y /\
     v = Quarter_points_differ (side_team s) x y).
Proof. unfold side_violations. rewrite in_app_iff, !in_differ. reflexivity. Qed.

Lemma in_gameb_spec g t : reflect (in_game g t) (in_gameb g t).
Proof.
  unfold in_game, in_gameb.
  destruct (team_eqb_spec t (side_team (home g))),
           (team_eqb_spec t (side_team (away g))); simpl; constructor; tauto.
Qed.

Lemma line_violations_nil g l : line_violations g l = [] <-> line_laws g l.
Proof.
  unfold line_violations, line_laws. rewrite app_nil_iff.
  destruct (N.eqb_spec (points l) (composed l)),
           (in_gameb_spec g (line_team l)); intuition congruence.
Qed.

Lemma in_line_violations g l v :
  In v (line_violations g l) <->
  (points l <> composed l /\
     v = Composition_differs (line_label l) (points l) (composed l)) \/
  (~ in_game g (line_team l) /\ v = Foreign_team (line_label l) (line_team l)).
Proof.
  unfold line_violations. rewrite in_app_iff.
  destruct (N.eqb_spec (points l) (composed l)),
           (in_gameb_spec g (line_team l)); simpl; intuition congruence.
Qed.

Lemma same_player_true p l : same_player p l = true <-> In p (player_of l).
Proof.
  unfold same_player, player_of. destruct (line_player l) as [q|]; simpl.
  - destruct (player_eqb_spec p q); intuition congruence.
  - intuition congruence.
Qed.

Lemma same_player_some p l : same_player p l = true -> line_player l = Some p.
Proof.
  unfold same_player. destruct (line_player l) as [q|]; [|discriminate].
  destruct (player_eqb_spec p q); [congruence | discriminate].
Qed.

Lemma existsb_same_player p ls :
  existsb (same_player p) ls = true <-> In p (known_players ls).
Proof.
  unfold known_players. rewrite existsb_exists, in_flat_map.
  split; intros (l & Hin & Hl); exists l; split; try assumption;
    apply same_player_true; assumption.
Qed.

Lemma repeated_nil ls : repeated ls = [] <-> NoDup (known_players ls).
Proof.
  induction ls as [|l ls IH].
  - simpl. split; intros; [constructor | reflexivity].
  - rewrite known_players_cons. simpl (repeated (l :: ls)).
    rewrite app_nil_iff, IH. unfold player_of.
    destruct (line_player l) as [p|]; simpl.
    + rewrite NoDup_cons_iff, <- existsb_same_player.
      destruct (existsb (same_player p) ls); intuition congruence.
    + intuition.
Qed.

Lemma in_repeated ls v :
  In v (repeated ls) <->
  exists before l after p, ls = before ++ l :: after /\ line_player l = Some p /\
    In p (known_players after) /\ v = Repeated_player (line_label l) p.
Proof.
  induction ls as [|l ls IH].
  - simpl. split; [tauto|].
    intros (before & l & after & p & H & _). destruct before; discriminate.
  - simpl (repeated (l :: ls)). rewrite in_app_iff, IH. split.
    + intros [Hhead | (before & m & after & p & Hls & Hm & Hin & Hv)].
      * revert Hhead. destruct (line_player l) as [p|] eqn:Hl; [|simpl; tauto].
        destruct (existsb (same_player p) ls) eqn:He; [|simpl; tauto].
        simpl. intros [Hv|[]].
        exists [], l, ls, p. split; [reflexivity|]. split; [assumption|]. split.
        -- apply existsb_same_player. assumption.
        -- symmetry. assumption.
      * exists (l :: before), m, after, p. rewrite Hls.
        repeat split; first [reflexivity | assumption].
    + intros (before & m & after & p & Hls & Hm & Hin & Hv).
      destruct before as [|b before]; simpl in Hls.
      * injection Hls as -> ->. left. rewrite Hm.
        apply existsb_same_player in Hin. rewrite Hin. simpl. left.
        symmetry. assumption.
      * injection Hls as -> Hls. right. exists before, m, after, p.
        repeat split; assumption.
Qed.

(** The checker reports nothing exactly when every law holds. *)
Theorem check_spec g : check g = [] <-> game_laws g.
Proof.
  unfold check, game_laws.
  rewrite !app_nil_iff, !side_violations_nil, flat_map_nil_iff, repeated_nil.
  split.
  - intros (H1 & H2 & H3 & H4). refine (conj H1 (conj H2 (conj _ H4))).
    eapply Forall_impl; [|exact H3]. intros l Hl. apply line_violations_nil. exact Hl.
  - intros (H1 & H2 & H3 & H4). refine (conj H1 (conj H2 (conj _ H4))).
    eapply Forall_impl; [|exact H3]. intros l Hl. apply line_violations_nil. exact Hl.
Qed.

Ltac flatten := repeat match goal with
  | H : _ /\ _ |- _ => destruct H
  | H : exists _, _ |- _ => destruct H
  | H : _ \/ _ |- _ => destruct H
  end.

(** Every report is a real failure with the stated numbers, and every
    failure is reported. *)
Theorem check_reports_exactly g v : In v (check g) <-> fails g v.
Proof.
  unfold check. rewrite !in_app_iff, !in_side_violations, in_flat_map, in_repeated.
  setoid_rewrite in_line_violations.
  destruct v as [t x y | t x y | lb x y | lb t | lb p]; simpl; split.
  - intros H. flatten; try discriminate;
      match goal with H : Box_points_differ _ _ _ = _ |- _ =>
        injection H; intros; subst end;
      first [ solve [exists (home g); intuition]
            | solve [exists (away g); intuition] ].
  - intros (s & [-> | ->] & Ht & Hf & Hb & Hne); subst t;
      [left; left | right; left; left]; exists x, y; repeat split; auto.
  - intros H. flatten; try discriminate;
      match goal with H : Quarter_points_differ _ _ _ = _ |- _ =>
        injection H; intros; subst end;
      first [ solve [exists (home g); intuition]
            | solve [exists (away g); intuition] ].
  - intros (s & [-> | ->] & Ht & Hf & Hq & Hne); subst t;
      [left; right | right; left; right]; exists x, y; repeat split; auto.
  - intros H. flatten; try discriminate.
    match goal with H : Composition_differs _ _ _ = _ |- _ =>
      injection H; intros; subst end.
    eexists. split; [eassumption | repeat split; auto].
  - intros (l & Hin & <- & <- & <- & Hne). right; right; left.
    exists l. split; [assumption | left; split; [assumption | reflexivity]].
  - intros H. flatten; try discriminate.
    match goal with H : Foreign_team _ _ = _ |- _ =>
      injection H; intros; subst end.
    eexists. split; [eassumption | repeat split; auto].
  - intros (l & Hin & <- & <- & Hn). right; right; left.
    exists l. split; [assumption | right; split; [assumption | reflexivity]].
  - intros H. flatten; try discriminate.
    match goal with H : Repeated_player _ _ = _ |- _ =>
      injection H; intros; subst end.
    do 3 eexists. split; [eassumption | repeat split; auto].
  - intros (before & l & after & Hls & <- & Hl & Hin). right; right; right.
    exists before, l, after, p. repeat split; assumption.
Qed.

(** * A consequence: games played never exceed the team's games *)

Definition rows_of (p : player) (t : team) (g : game) : nat :=
  length (filter (fun l => same_player p l && team_eqb (line_team l) t) (lines g)).

Fixpoint player_rows (p : player) (t : team) (gs : list game) : nat :=
  match gs with
  | [] => 0
  | g :: rest => rows_of p t g + player_rows p t rest
  end.

Fixpoint team_games (t : team) (gs : list game) : nat :=
  match gs with
  | [] => 0
  | g :: rest => (if in_gameb g t then 1 else 0) + team_games t rest
  end.

Lemma filter_absent p f ls :
  ~ In p (known_players ls) ->
  filter (fun l => same_player p l && f l) ls = [].
Proof.
  induction ls as [|l ls IH]; intros Hp; [reflexivity|].
  rewrite known_players_cons, in_app_iff in Hp. simpl.
  destruct (same_player p l) eqn:Hs.
  - exfalso. apply Hp. left. apply same_player_true. assumption.
  - simpl. apply IH. intros H. apply Hp. right. assumption.
Qed.

Lemma rows_le_one p f ls :
  NoDup (known_players ls) ->
  length (filter (fun l => same_player p l && f l) ls) <= 1.
Proof.
  induction ls as [|l ls IH]; intros Hnd; simpl; [lia|].
  rewrite known_players_cons in Hnd.
  destruct (same_player p l && f l) eqn:Hs; simpl.
  - apply andb_true_iff in Hs as [Hs _]. apply same_player_some in Hs.
    unfold player_of in Hnd. rewrite Hs in Hnd. simpl in Hnd.
    apply NoDup_cons_iff in Hnd as [Hn _].
    rewrite filter_absent by exact Hn. simpl. lia.
  - apply IH. eapply NoDup_app_r. exact Hnd.
Qed.

Lemma filter_team_absent p t g ls :
  Forall (line_laws g) ls -> in_gameb g t = false ->
  filter (fun l => same_player p l && team_eqb (line_team l) t) ls = [].
Proof.
  intros Hall Hplay. induction Hall as [|l ls [_ Hin] _ IH]; [reflexivity|].
  simpl. destruct (team_eqb_spec (line_team l) t) as [Ht|Ht].
  - exfalso. subst t. apply (reflect_iff _ _ (in_gameb_spec g (line_team l))) in Hin.
    congruence.
  - rewrite andb_false_r. exact IH.
Qed.

Lemma rows_of_bound p t g :
  game_laws g -> rows_of p t g <= if in_gameb g t then 1 else 0.
Proof.
  intros (_ & _ & Hlines & Hnd). unfold rows_of.
  destruct (in_gameb g t) eqn:Hplay.
  - apply rows_le_one. exact Hnd.
  - rewrite filter_team_absent with (g := g) by assumption. simpl. lia.
Qed.

(** When the checker reports nothing for every game of a season, a player's
    rows for a team never outnumber that team's games. *)
Theorem rows_bounded p t gs :
  Forall (fun g => check g = []) gs -> player_rows p t gs <= team_games t gs.
Proof.
  induction 1 as [|g gs Hg _ IH]; simpl; [lia|].
  apply check_spec in Hg. pose proof (rows_of_bound p t g Hg) as Hb.
  revert Hb. destruct (in_gameb g t); intros Hb; lia.
Qed.

End Laws.
