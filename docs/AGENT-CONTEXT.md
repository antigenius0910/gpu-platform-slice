# How I prepared the agent for the live extension

**Written 1 October 2026, after the panel. Not part of the submission.** `main` and the tag
`submission-2026-09-30` are unchanged. `CLAUDE.md` on this branch is the file that sat in my
working tree during the panel, unedited. It was git-excluded then, so it never appeared in the repo.
The file and its tests are preparation for the live extension, done on the morning of 1 October,
after the submission was frozen. The two rehearsal changes it was tested against were built on
local branches on 29 September.

## Why a rules file

The live extension was about 25 minutes. An agent that starts cold spends that time rediscovering
the repository, and it will make the mistakes I already made once. `CLAUDE.md` gives it four things:

- **Hard rules.** Never push. Run `make verify` after every change. Prove a new check can fail.
- **The entitlement contract**, and the exact files to touch for a new field, a new value, or a new quota.
- **`verify.sh` conventions.** Assert the event, not the status. Assert the reason, not the phase.
- **Traps that had already cost me time**, each with its error message.

## I tested the file, not the agent

A rules file is a claim: "an agent with no other context can work correctly from this." I tested
that claim the same way the slice tests its own.

- **Two tasks with known answers.** I had already built both on local branches as rehearsals:
  a third priority tier `batch` below `low`, and CPU and memory caps in the entitlement.
- **A blind tester for each.** A fresh agent in an isolated clone with its own cluster name. The
  prompt was the same word for word in every round. The tester was forbidden to read the reference
  branch until it had written its report.
- **The report was about the file.** What helped, what was missing, wrong or unclear, which traps
  it hit that the file did not warn about. Only then did it diff its work against the reference.
- **Predictions first.** Before the first run I wrote down eight gaps I expected. The testers
  reported four of them and found twelve I had not predicted.

I applied the findings and ran the same prompts again, three rounds in all.

| | Round 1 | Round 2 | Round 3 |
|---|---|---|---|
| `CLAUDE.md` length | 91 lines | 156 lines | 179 lines |
| Task A, `batch` tier: verify result | 29 passed, 0 failed | 29 / 0 | 32 / 0 |
| Task A: missed against the reference | one thing | nothing | nothing |
| Task A: traps the file did not warn about | 3 | 1 | 1 |
| Task B, CPU and memory caps: verify result | 33 passed, 0 failed | 33 / 0 | 39 / 0 |
| Task B: missed against the reference | nothing | nothing | nothing |
| Task B: traps the file did not warn about | 4 | 2 | 2 |
| Rules the testers quoted as useful (A / B) | 7 / 7 | 9 / 9 | 12 / 10 |

Every pre-existing case passed in every run. The file on this branch is 204 lines: round 3's
findings were small and certain, so I applied them without a fourth round.

## What the rounds changed

- **Two statements in the first version were wrong**, and both were removed: that `make render`
  prints rendered output, and that a case must call `converge` itself.
- **"Add a field" and "add a value" were one instruction.** The first version said to edit all
  three tenant specs. That is right for a new required field and wrong for a new tier: moving a real
  team onto `batch` breaks the `capacity` and `preemption` cases. They are now two procedures.
- **PriorityClass fields are immutable.** In round 1 the tester hit `field is immutable` and had to
  work it out. In round 2 the file said "delete and re-apply", and the same failure cost seconds.

## What the test found in my own work

- **My reference solution for `batch` was weaker than the tester's.** It proved that `low` preempts
  `batch`. It never proved that `batch` preempts nothing. Removing `preemptionPolicy: Never` left my
  version green. The tester asserted the scheduler's own reason,
  `not eligible due to preemptionPolicy=Never`, and showed that only that check catches it.
- **Both of my reference solutions left the docs stale.** Both testers updated them.
- **A sentence in the submission is wrong.** `docs/production-design.md` on `main` says CPU and
  memory ceilings go "in the same quota". The tests showed they belong in their own ResourceQuota:
  the `escalation` case names `gpu-cap`, and `kubectl auth can-i patch` on a renamed or missing
  object still prints `no`, so a rename would pass silently. I have left `main` as submitted.

## Limits

- The testers were background subagents, not fresh interactive sessions. They were told to read
  `CLAUDE.md`; it was not auto-loaded.
- Two tasks is a small sample, and both were my own guesses at what the live extension might be.
- The number of gaps reported did not fall (9 and 10 in round 1, 8 and 9 in round 3). Their kind
  changed: missing structure, then missing operational detail, then polish.
- Round 3's file states some answers outright. That round measures how well an agent works from a
  good file, not whether it can find the gaps itself.
- Timings across rounds are not comparable. In round 2 the two testers wrote logs to one directory
  and one overwrote the other's, a fault in my harness that cost about four minutes.
