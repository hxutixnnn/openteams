# Repository rules

## Workflow

- Inspect the current working tree and project conventions before making changes. Follow existing commit, branch, naming and code conventions.
- Confirm intent and scope before implementation.
- Never post comments on GitHub, Jira or Confluence on the user's behalf without approval.
- Prefer the in-app browser for UI visual testing when applicable.
- Always use `gh stack` when creating stacked PRs.
- Do not wait for chat replies; teammates will ping back.

## Implementation and validation

- Skip unit tests entirely. Do not write or run unit tests; write and run end-to-end (E2E) tests instead.
- Code comments are prohibited. Write self-explanatory code through clear naming and simple structure.
- Prioritize maintainability. Remove unused code within the agreed scope, make the smallest necessary changes, and avoid speculative abstractions or unrelated cleanup.
