# AGENTS.md

## Development

- Create one PR for each issue.
- Use Node.js for TypeScript/JavaScript tooling and test helpers.
- Use `npm install` to install JavaScript dependencies.
- Use `node <script>` for JavaScript/TypeScript helper scripts.
- Use only Node.js APIs and commands for JavaScript and TypeScript.

## Swift Concurrency

- Actors wrapping foreign threaded libraries: treat native handles owned by the actor as references, not as objects safe to destroy on the actor’s executor. Offload blocking teardown to a dedicated queue, stop ingress before clearing actor state, and don’t await native shutdown from the actor.

## Git

No "Co-Authored-By: Claude" trailer.
No "Generated with" line.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues (`siuying/SwiftYrs`), managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
