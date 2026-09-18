# Issue tracker: GitHub

Issues and specs for this repo live in GitHub Issues for `ranokay/glance`. Use the `gh` CLI with `--repo ranokay/glance` for all operations.

## Conventions

- **Create an issue**: `gh issue create --repo ranokay/glance --title "..." --body "..."`. Use a heredoc for multiline bodies.
- **Read an issue**: `gh issue view <number> --repo ranokay/glance --comments`, including its labels.
- **List issues**: `gh issue list --repo ranokay/glance --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --repo ranokay/glance --body "..."`
- **Apply or remove labels**: `gh issue edit <number> --repo ranokay/glance --add-label "..."` or `--remove-label "..."`
- **Close an issue**: `gh issue close <number> --repo ranokay/glance --comment "..."`

## Pull requests as a triage surface

**PRs as a request surface: no.** Set this to `yes` if the repo starts treating external pull requests as feature requests.

When set to `yes`, pull requests use the same labels and states as issues:

- **Read a pull request**: `gh pr view <number> --repo ranokay/glance --comments` and `gh pr diff <number> --repo ranokay/glance`.
- **List external pull requests**: `gh pr list --repo ranokay/glance --state open --json number,title,body,labels,author,authorAssociation,comments`. Keep only `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, or `NONE` author associations.
- **Comment, label, or close**: use `gh pr comment`, `gh pr edit`, or `gh pr close` with `--repo ranokay/glance`.

GitHub shares one number sequence across issues and pull requests. Resolve a bare reference such as `#42` with `gh pr view 42 --repo ranokay/glance`, then fall back to `gh issue view 42 --repo ranokay/glance`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue in `ranokay/glance`.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --repo ranokay/glance --comments`.

## Wayfinding operations

The `/wayfinder` skill represents a map as one issue and its tickets as child issues.

- **Map**: an issue labelled `wayfinder:map` that contains Notes, Decisions-so-far, and Fog sections.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue. If sub-issues are unavailable, add it to a task list in the map and put `Part of #<map>` at the top of the child issue. Apply a `wayfinder:<type>` label using `research`, `prototype`, `grilling`, or `task`.
- **Blocking**: use GitHub's native issue dependencies. Add an edge with `gh api --method POST repos/ranokay/glance/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`. Fetch the numeric database ID with `gh api repos/ranokay/glance/issues/<number> --jq .id`. If dependencies are unavailable, add `Blocked by: #<number>` at the top of the child issue.
- **Frontier query**: list the map's open children, then exclude assigned tickets and tickets with open blockers. The first remaining ticket in map order wins.
- **Claim**: `gh issue edit <number> --repo ranokay/glance --add-assignee @me`. This is the session's first write.
- **Resolve**: comment with the answer, close the ticket, then add a context pointer and link to the map's Decisions-so-far section.
