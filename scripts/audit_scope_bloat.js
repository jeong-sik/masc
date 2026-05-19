#!/usr/bin/env node
/**
 * Audit tasks/goals for scope bloat and unnecessary complexity.
 * Node.js version for masc_code_shell compatibility.
 */

const fs = require('fs');

const VAGUE_MARKERS = [
  "etc", "and so on", "and more", "future work", "TBD", "TODO",
  "placeholder", "stub", "coming soon", "not yet defined",
  "to be determined", "to be decided", "flesh out", "fill in",
  "eventually", "later", "at some point", "when needed",
];

const BROAD_VERBS = [
  "improve", "enhance", "optimize", "refactor", "clean up",
  "make better", "streamline", "simplify", "modernize",
];

const ACCEPTANCE_KEYWORDS = [
  "acceptance", "criteria", "done when", "definition of done",
  "verify", "checklist", "measurable", "metric", "benchmark",
  "test passes", "ci green", "reviewed", "approved",
];

function countWords(text) {
  return text.split(/\s+/).filter(w => w.length > 0).length;
}

function findVagueMarkers(text) {
  const lower = text.toLowerCase();
  return VAGUE_MARKERS.filter(m => lower.includes(m));
}

function findBroadVerbs(text) {
  const lower = text.toLowerCase();
  return BROAD_VERBS.filter(v => new RegExp(`\\b${v}\\b`).test(lower));
}

function hasAcceptanceCriteria(text) {
  const lower = text.toLowerCase();
  return ACCEPTANCE_KEYWORDS.some(kw => lower.includes(kw));
}

function countObjectives(text) {
  const splits = text.toLowerCase().split(/[.!?;]|\band\b|\balso\b|\bplus\b|\badditionally\b/);
  const verbish = /\b(implement|build|create|fix|add|remove|update|write|design|integrate|deploy|test|audit|refactor|optimize|migrate)\b/;
  return splits.filter(s => verbish.test(s)).length;
}

function hasNestedSubtasks(text) {
  const patterns = [
    /^\s*[-*•]\s+/m,
    /^\s*\d+[.)]\s+/m,
    /\bsubtask\b|\bsub-task\b|\bchild task\b/i,
    /\bstep\s+\d+\b|\bphase\s+\d+\b/i,
  ];
  return patterns.some(p => p.test(text));
}

function auditTask(task) {
  const findings = [];
  const taskId = task.id || task.task_id || "unknown";
  const title = task.title || "";
  const description = task.description || task.body || "";
  const fullText = `${title} ${description}`;

  const wordCount = countWords(fullText);
  if (wordCount > 80) {
    findings.push({ severity: "critical", category: "word_count",
      message: `Description is ${wordCount} words — likely contains multiple objectives or excessive detail`,
      evidence: `word_count=${wordCount}` });
  } else if (wordCount > 50) {
    findings.push({ severity: "high", category: "word_count",
      message: `Description is ${wordCount} words — consider splitting into smaller tasks`,
      evidence: `word_count=${wordCount}` });
  }

  const vague = findVagueMarkers(fullText);
  if (vague.length > 0) {
    findings.push({ severity: "high", category: "vague_scope",
      message: `Contains vague scope markers: ${vague.join(", ")}`,
      evidence: `markers=${JSON.stringify(vague)}` });
  }

  const broad = findBroadVerbs(fullText);
  const hasMetrics = /\b\d+%?\b|\b[0-9]+\s*(ms|sec|min|hour|day|req|qps|rps)\b/.test(fullText.toLowerCase());
  if (broad.length > 0 && !hasMetrics) {
    findings.push({ severity: "medium", category: "broad_objective",
      message: `Uses broad verb(s) without measurable target: ${broad.join(", ")}`,
      evidence: `verbs=${JSON.stringify(broad)}, has_metrics=${hasMetrics}` });
  }

  if (!hasAcceptanceCriteria(fullText)) {
    findings.push({ severity: "medium", category: "missing_acceptance",
      message: "No acceptance criteria or 'done when' clause detected",
      evidence: `No keywords: ${ACCEPTANCE_KEYWORDS.slice(0, 5).join(", ")}...` });
  }

  const objCount = countObjectives(description);
  if (objCount > 3) {
    findings.push({ severity: "high", category: "multiple_objectives",
      message: `Appears to contain ${objCount} distinct objectives — consider splitting`,
      evidence: `estimated_objectives=${objCount}` });
  } else if (objCount > 2) {
    findings.push({ severity: "medium", category: "multiple_objectives",
      message: `May contain ${objCount} objectives — verify scope is focused`,
      evidence: `estimated_objectives=${objCount}` });
  }

  if (hasNestedSubtasks(description)) {
    findings.push({ severity: "high", category: "nested_subtasks",
      message: "Description contains list items or explicit subtask references — this task may be an epic",
      evidence: "Detected bullet/number/subtask patterns" });
  }

  return { taskId, title, findings };
}

function scoreTask(findings) {
  const weights = { low: 1, medium: 3, high: 6, critical: 10 };
  return findings.reduce((sum, f) => sum + (weights[f.severity] || 1), 0);
}

function printReport(results, totalTasks) {
  const allFindings = results.flatMap(r => r.findings);
  if (allFindings.length === 0) {
    console.log(`✅ Audited ${totalTasks} tasks: no scope bloat detected.`);
    return;
  }

  const byTask = {};
  for (const r of results) {
    if (r.findings.length > 0) byTask[r.taskId] = r;
  }

  console.log(`\n${"=".repeat(60)}`);
  console.log(`SCOPE BLOAT AUDIT REPORT — ${totalTasks} tasks scanned`);
  console.log(`${"=".repeat(60)}`);

  const scored = Object.values(byTask).map(r => ({
    ...r,
    score: scoreTask(r.findings)
  })).sort((a, b) => b.score - a.score);

  for (const r of scored) {
    console.log(`\n🔍 Task: ${r.taskId} | Bloat Score: ${r.score}`);
    console.log(`   Title: ${r.title}`);
    for (const f of r.findings) {
      const icon = { low: "⚪", medium: "🟡", high: "🔴", critical: "🚨" }[f.severity] || "⚪";
      console.log(`   ${icon} [${f.severity.toUpperCase()}] ${f.category}: ${f.message}`);
      console.log(`      Evidence: ${f.evidence}`);
    }
  }

  const critical = allFindings.filter(f => f.severity === "critical").length;
  const high = allFindings.filter(f => f.severity === "high").length;
  const medium = allFindings.filter(f => f.severity === "medium").length;
  const low = allFindings.filter(f => f.severity === "low").length;

  console.log(`\n${"=".repeat(60)}`);
  console.log(`SUMMARY: ${scored.length}/${totalTasks} tasks flagged`);
  console.log(`  Critical: ${critical} | High: ${high} | Medium: ${medium} | Low: ${low}`);
  console.log(`${"=".repeat(60)}`);
}

function main() {
  const inputFile = process.argv[2];
  const raw = inputFile ? fs.readFileSync(inputFile, 'utf8') : fs.readFileSync(0, 'utf8');
  let data;
  try {
    data = JSON.parse(raw);
  } catch (e) {
    console.error("Invalid JSON:", e.message);
    process.exit(1);
  }

  const tasks = Array.isArray(data) ? data : (data.tasks || data.goals || data.items || []);
  if (tasks.length === 0) {
    console.error("No tasks found in input.");
    process.exit(1);
  }

  const results = tasks.map(auditTask);
  printReport(results, tasks.length);
}

main();