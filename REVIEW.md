# Revue de Duet-Symphony — Spec v0.2.0

**Reviewer:** Claude Opus 4.6
**Date:** 2026-05-10
**Spec version:** 0.2.0 (draft)
**Direction:** Symphony-compatible fork with Duet pair-runtime worker

> Historical review note: this file reviews spec v0.2.0. R1-R6 and R8 were
> integrated into the normative spec before the v0.3.0 agent-routing and
> SuperPower artifact amendments; R7 remains operator documentation here.

---

## Verdict global

La v0.2.0 est un repositionnement stratégique majeur par rapport à la v0.1.0. Le projet n'est plus un harness standalone qui s'inspire de Symphony — c'est Symphony avec un worker duo. Ce choix est le bon. Il ancre Duet sur une base opérationnelle prouvée (tracker, workspaces, hooks, retry, observability) et réduit la surface d'invention au strict nécessaire : le pair-loop et le convergence protocol.

La spec est prête pour l'implémentation. Les risques restants sont identifiés ci-dessous comme backlog actionable.

---

## Ce qui est solide

### Positionnement upstream-first (§1.2, §1.3)
La stratégie fork/overlay avec upstream merge checklist est la bonne approche. Le §1.3 rend explicite ce qui était implicite dans la v0.1 : on ne réécrit pas Symphony, on le patch. La contrainte "smallest possible Duet patch set" (AGENTS.md) est un bon garde-fou contre le scope creep.

### Agent runtime abstraction (§7.1, §7.3)
Le passage de "CLI sessions" à "agent runtimes" est un gain significatif. La spec nomme les bons backends : Codex App Server (JSON-RPC/JSONL) pour Codex, Claude Code `--print --output-format stream-json` (+ `--resume`/`--session-id`) pour Claude. L'interactive stdin/stdout est explicitement rétrogradé en fallback. C'est le bon call — les protocoles structurés sont plus fiables que le TTY scraping.

### Configuration via WORKFLOW.md (§12)
Garder le contrat Symphony `WORKFLOW.md` avec front-matter YAML et ajouter les settings Duet sous une clé `duet:` est élégant. Ça préserve la compatibilité upstream et rend le delta lisible.

### Transport modes enrichis (§7.6)
`local_pair` et `cloud_pair` remplacent `cli_session` et couvrent mieux la réalité opérationnelle. Le mapping `hybrid` par défaut (local pour SPEC/PLAN/CODE, bot pour REVIEW) reste le bon compromis.

### Convergence protocol inchangé (§10)
Le split-signal model, le pathological disagreement detector, et le tie-breaker différencié (SPEC/PLAN vs CODE) sont les mêmes qu'en v0.1 — et c'est bien. C'est la partie la plus aboutie de la spec.

### Tracker-driven lifecycle (§5)
L'intégration Linear comme tracker first-class et le CLI `duet run` comme extension secondaire est le bon ordonnancement pour un produit qui cible Symphony parity.

---

## Backlog de risques pour v0.2.0

### R1 — Trailer validation sémantique
**Risque :** Un agent produit un trailer syntaxiquement valide mais sémantiquement incohérent.
**Exemples :** `verdict: APPROVE` avec `unresolved: [3 items]`, ou `confidence: 0.1` avec `verdict: APPROVE`.
**Impact :** Fausse convergence sur un artifact contesté.
**Action recommandée :** Ajouter au §10.1 des validations :
- `APPROVE` + `unresolved` non-vide → warning + re-prompt
- `confidence < 0.3` + `APPROVE` → warning dans l'event log
- `REQUEST_CHANGES` + `unresolved` vide → synthétiser `unresolved: [no_details_provided]`

### R2 — Conflict policy pendant REVIEW
**Risque :** Le CODE PR reste ouvert pendant REVIEW (§8.2-8.3). Chaque task a sa propre `duet-base/<task_id>`, donc un autre task ne peut pas faire avancer cette branche. En revanche, une modification externe (rebase/merge manuel par l'opérateur, commit poussé directement sur la branche task) ou un conflit au moment de lander `duet-base/<task_id>` vers `main` peut rendre le merge impossible après convergence.
**Impact :** REVIEW convergé mais merge bloqué ; travail des agents gaspillé.
**Action recommandée :** Spécifier le comportement dans §8.3 :
- Détecter les conflits avec la base avant le merge final
- Si conflit au moment du land vers `duet-base` : alerter l'opérateur
- Si conflit au moment du land vers `main` : hors scope Duet (responsabilité opérateur), mais documenter le risque

### R3 — Recovery après divergence event log / état GitHub
**Risque :** Au restart, l'event log dit "SPEC frozen, PLAN en cours" mais GitHub montre un état différent (PR mergée qu'on ne s'attend pas, ou PR manquante).
**Impact :** État incohérent, potentielle corruption silencieuse.
**Action recommandée :** Définir dans §11 une hiérarchie de vérité au restart :
1. État GitHub (PRs, reviews) = source primaire observable (les review states sont fiables ; les PR bodies/comments peuvent être édités, donc traiter les reviews comme signal fort et les commentaires comme signal faible)
2. Branch tips = confirmation
3. Event log = complément pour les données non-GitHub (cycles, verdicts internes)
4. En cas de conflit : halt + alerte opérateur plutôt que réconciliation automatique

### R4 — Pause-on-freeze opérateur
**Risque :** En early adoption, un opérateur veut vérifier chaque artifact frozen avant de laisser le pair-loop continuer. Pas de mécanisme prévu.
**Impact :** Obligation de laisser tourner en aveugle ou de surveiller manuellement les PRs.
**Action recommandée :** Ajouter `duet.pause_on_freeze: true|false` (default `false`). Quand activé, la task passe en `awaiting_operator` après chaque phase-freeze, avec `duet resolve <task_id> --continue` pour reprendre. Correspond à la question ouverte §18.10.

### R5 — Résumé de phase-freeze adaptatif
**Risque :** Le cap de ~1500 mots (§8.4) est un guess fixe. Un SPEC de 200 mots n'a pas besoin de 1500 mots de résumé ; un CODE diff de 2000 lignes en a besoin de plus.
**Impact :** Résumé trop verbeux (gaspillage de context) ou trop court (perte d'information critique).
**Action recommandée :** Formule adaptative :
- SPEC/PLAN : min(1500, artifact_word_count * 0.5) mots
- CODE : min(3000, diff_lines * 2) mots
- Plancher : 300 mots

### R6 — Trailer injection adversariale
**Risque :** §10.1 dit "parser uniquement le dernier bloc valide". Mais un agent pourrait être amené (par prompt injection dans le code source qu'il review) à émettre un trailer forgé.
**Impact :** Convergence manipulée par du contenu hostile dans le repo.
**Note :** Le schema actuel du trailer (§10.1) ne contient pas de champ `tree_hash`. L'orchestrateur associe chaque réponse au HEAD observé au moment du turn. Le risque d'injection porte donc sur le verdict et la confidence, pas sur le tree-hash.
**Action recommandée :** Ajouter une validation de chaîne :
- Le trailer DOIT être dans les N dernières lignes de la réponse (pas enfoui au milieu)
- L'orchestrateur DOIT associer le verdict au HEAD de la phase branch au moment du turn (déjà le cas implicitement, mais à rendre explicite dans §10.1)
- Si un trailer est rejeté (position invalide, parsing échoué après re-prompt), émettre un événement `trailer_rejected` dans l'event log avec le motif, plutôt que de l'ignorer silencieusement

### R7 — Distinct GitHub identities : barrière d'entrée
**Risque :** Le split-signal model exige deux identités GitHub distinctes (§9.3, §16). C'est une exigence de conformance.
**Impact :** Un développeur solo qui veut tester Duet doit créer et configurer deux service accounts GitHub avant même de lancer un premier run.
**Action recommandée :** Pas de changement à la spec prod. Mais documenter un "quick start" qui fonctionne avec : (1) le compte humain + un service account, ou (2) deux GitHub Apps gratuites. Et clarifier que le mode `DUET_DRY_RUN` bypass cette contrainte pour le développement local.

### R8 — Claude runtime parity (§18.5)
**Risque :** Claude Code n'expose pas le même App Server protocol que Codex. L'invocation structurée est `claude --print --output-format stream-json` (avec `--resume` et `--session-id` pour la persistance). C'est fonctionnel mais moins riche que Codex App Server (pas de JSON-RPC bidirectionnel, pas de thread sandbox natif).
**Impact :** Asymétrie entre les deux agents — Codex a un runtime plus propre, Claude est en mode "meilleur effort".
**Action recommandée :** C'est un fait connu, pas un bug de spec. L'adapter Claude Code devra gérer : parsing du stream-json, gestion des session IDs pour resume, et fallback propre si `--print` échoue. Documenter les limites connues dans §17. Corriger aussi la référence dans §12 config example (la ligne actuelle `command: ["claude", "--print", "--output-format", "stream-json"]` est correcte).

---

## Points conservés de la revue v0.1.0

Les observations suivantes étaient dans la revue initiale et restent valides en v0.2.0 :

- **Pathological disagreement detector** (§10.5) : mécanisme critique et bien conçu.
- **CODE phase escalation** : le default `escalate` est le bon choix sécuritaire.
- **Phase-freeze comme ancrage de contexte** : toujours la bonne approche pour la context window pressure.
- **Abstraction interne `agent_a`/`agent_b`** : le passage de la v0.2 aux termes "agent runtimes" va dans ce sens. Confirmer que l'implémentation utilise des noms internes génériques même si le produit reste "Claude + Codex".

---

## Positions sur les questions ouvertes de §18

| # | Question | Position |
|---|----------|----------|
| 1 | CODE implementer choice | Garder default Codex + override dans PLAN. Mécanisme simple (un champ dans PLAN.md), flexibilité utile. |
| 2 | Upstream patch shape | Fork avec upstream remote + petit patch stack. Plus maintenable qu'un subtree pour un projet activement développé des deux côtés. |
| 3 | Agent runtime boundary | Oui, garder single-Codex comme compatibility mode. Ça valide que le boundary est propre. |
| 4 | Codex Cloud | CODE uniquement pour v1. SPEC/PLAN n'ont pas besoin de la latence async. |
| 5 | Claude runtime | `--print --output-format stream-json` + `--resume`/`--session-id` comme adapter primaire. Bot mode en fallback. |
| 6 | Phase-freeze summary | Adaptatif (voir R5 ci-dessus). |
| 7 | Single vs multi-commit CODE PR | Single PR pour v1. Progressive review est un v2 feature. |
| 8 | Reviewer-driven amendments | Oui pour CODE phase, avec confirmation Author via trailer. |
| 9 | Cross-phase memory pruning | Restart runtime avec recovery message pour v1. |
| 10 | Operator-in-the-loop | Oui, `pause_on_freeze` flag (voir R4 ci-dessus). Default `false`. |
| 11 | Failure replay | Restart-from-phase-boundary suffisant pour v1. |

---

## Score

| Aspect | Note | Delta vs v0.1 |
|--------|------|---------------|
| Clarté | A | = |
| Complétude | A | + (upstream strategy, runtime details) |
| Faisabilité | A- | + (s'appuie sur Symphony existant) |
| Innovation | A | = (convergence protocol inchangé) |
| Risques identifiés | B+ | = (R1-R8 ci-dessus couvrent les gaps) |
| Pragmatisme | A | ++ (Symphony base = moins à construire) |

**Score global : A**

Le repositionnement sur Symphony parity est le bon move. La spec est actionable. Les 8 risques ci-dessus sont un backlog raisonnable, aucun n'est bloquant pour démarrer l'implémentation.
