---
name: multi-agent-review
description: >-
  Runs an on-demand plan→grill→plan-review→implement→code-review loop with
  separate models for planning/review vs coding, and explicit accept-or-dismiss
  triage of review findings. Use when the user asks for a multi-agent review,
  reviewed change, plan then code with reviews, pre-merge multi-agent review,
  or invokes /multi-agent-review.
---

# Multi-agent review

On-demand workflow for non-trivial changes before merge. Orchestrator owns
planning, triage, and gates; subagents own plan review, implementation, and
code review.

## Dependencies

Requires upstream **grill-me** (Matt Pocock). Do **not** copy or fork it into
this repo.

```bash
npx skills add https://github.com/mattpocock/skills --skill grill-me
npx skills update grill-me
```

If `/grill-me` is missing when the ambiguity gate runs, stop and show those
commands. Do not paste a stale inline copy of grilling instructions.

## Model defaults

Use these unless the user names different models. Do not block on model choice.

| Role | Cursor Task `model` | Intent |
|------|---------------------|--------|
| Plan drafting, plan review, code review | `claude-opus-5-thinking-high` | Expensive / careful |
| Implementation subagent | `claude-sonnet-5-thinking-high` | Cheaper coding |
| Optional second code review | `gpt-5.6-sol-medium` (or later GPT slug if listed) | Cross-family check |

Claude Code: pick Opus / Sonnet / GPT equivalents when those models are available.

## Progress checklist

Copy and tick as you go:

```
Multi-agent review:
- [ ] 1. Plan drafted (Plan mode / expensive model)
- [ ] 2. Ambiguity resolved via /grill-me (or N/A)
- [ ] 3. Plan review complete; findings triaged
- [ ] 4. Implementation complete (coding subagent)
- [ ] 5. Code review complete; findings triaged
- [ ] 6. Accepted findings fixed
- [ ] 7. Optional CodeRabbit pass (at most once)
```

## Workflow

### 1. Draft plan

Draft in Plan mode with the expensive/planning model. Cover scope, approach,
files touched, risks, and open decisions. Use the **`/grill-me`** skill to resolve
ambiguity in the plan and resolve open questions. If grill-me is unavailable, stop
with install/update instructions from Dependencies.

### 2. Plan review

Spawn a fresh review subagent (expensive model) with the approved plan and
relevant codebase context. Defect-first. Use the plan-review prompt below.

### 3. Triage plan review

For each finding, either:

- **Accept** — update the plan accordingly, or
- **Dismiss** — write a short reason

Do not silently ignore findings. Show a triage table before implementing.

### 4. Implement

Spawn a coding subagent (cheaper model) against the triaged plan. Prefer the
subagent for large implementation; orchestrator stays on coordination and gates.

### 5. Code review

Spawn a review subagent (expensive model) over the branch or uncommitted diff.
Optionally run a second GPT-family pass. Use `bugbot` / `security-review` only
when the user asks for those specifically; default is general defect-first
review. Use the code-review prompt below.

### 6. Triage code review

Same accept-or-dismiss-with-reasons discipline as step 4. Fix accepted findings
with the coding model before claiming ready to merge.

### 7. Optional CodeRabbit

If local changes exist and CodeRabbit is installed and the user has not disabled
it, run once:

```bash
coderabbit --agent -t uncommitted
```

At most once per change set. Not an infinite review loop.

### 9. Stop

Stop unless the user asks to commit, open an MR/PR, or re-run review.

## Review prompts

### Plan review

Give the subagent:

```text
You are reviewing an approved implementation plan before coding.

Plan:
<approved plan>

Context:
<relevant paths / constraints>

Review defect-first. Flag missing decisions, wrong assumptions, unsafe
operations, scope gaps, and better simpler approaches. Ignore style nits.

For each finding use:
- Severity: Critical | High | Medium | Low
- Location: plan section or topic
- Finding: what is wrong or missing
- Suggested fix: concrete change to the plan
```

### Code review

Give the subagent:

```text
You are reviewing code changes before merge.

Diff scope: <branch changes | uncommitted changes>
Plan intent:
<short summary of approved / triaged plan>

Review defect-first: bugs, security, correctness, missing tests, vault/prod
safety, and regressions. Ignore pure style unless it hides a bug.

For each finding use:
- Severity: Critical | High | Medium | Low
- Location: file:line (or file)
- Finding: what is wrong
- Suggested fix: concrete change
```

## Triage table (orchestrator)

After each review, publish:

```markdown
| Severity | Location | Finding | Decision |
|----------|----------|---------|----------|
| High | ... | ... | Accepted — <how addressed> |
| Medium | ... | ... | Dismissed — <reason> |
```

Every finding needs a Decision. Accepted items must be reflected in the plan
(step 4) or the code (step 7) before proceeding.

## Do not

- Skip user plan approval
- Skip triage or silently drop findings
- Implement before plan review (and its triage)
- Claim ready to merge with unaddressed accepted findings
- Copy or fork grill-me into this repository
- Run CodeRabbit more than once per change set unless the user asks

## Cursor appendix

Use the Task tool:

| Step | `subagent_type` | `model` |
|------|-----------------|--------|
| Plan review | `generalPurpose` | `claude-opus-5-thinking-high` |
| Implement | `generalPurpose` | `claude-sonnet-5-thinking-high` |
| Code review | `generalPurpose` | `claude-opus-5-thinking-high` |
| Optional 2nd review | `generalPurpose` | `gpt-5.6-sol-medium` |

Set `run_in_background: false` unless the user asks otherwise. Pass the full
plan or diff scope in `prompt`. For specialized reviews only when requested:
`bugbot` or `security-review` per those skills.

## Claude Code appendix

Use Agent/Task with Opus for plan + reviews, Sonnet for implementation, and an
available GPT model for an optional second review. Same prompts and triage
rules as above. Invoke `/grill-me` at the ambiguity gate; if missing, stop with
skills.sh install/update commands.
