# Notes on AI use

The brief asks what I delegated, what context I gave, how I checked the result, and for one
correction or rejected suggestion. This page answers all four for the code in this repository,
and then for the throwaway prototype that came before it.

## What I delegated

I used Claude Code for most of the typing and kept the decisions. Specifically, I delegated:

- A first draft of every file in `slice/`: the chart, the admission policy, `create.sh`,
  `verify.sh`, and `destroy.sh`, written against a design sketch I had approved first.
- The CI workflow, and reading CI logs when a run failed.
- Re-framing a long production design document into `production-design.md`. A separate agent
  did this with a list of measured facts it had to preserve and names it had to keep out.
- Research with citations, for example the Kubernetes release that changed the default of
  `node-monitor-grace-period`.

I kept these decisions and made each one myself:

- k3d with a pinned k3s image, standard NetworkPolicy, and two labelled GPU pools.
- The three teams, their caps and tiers, and the oversubscription arithmetic.
- The demo entry point: local `make verify`, with hosted CI as evidence.
- How to close the tier-borrowing gap. The agent proposed three options and I chose the
  ValidatingAdmissionPolicy.

## What context I gave

- The assignment text verbatim, and a build specification that listed every settled decision
  with the evidence behind it.
- A design audit with 26 numbered findings, so any "why is it this way" had an answer on file.
- Measurements from the prototype: timings, and the two facts earlier documents had wrong
  (GPU capacity survives a restart, and it is not zeroed when a node goes `NotReady`).
- An assertion standard: assert the event, not the status. Assert the reason, not the phase.
  Every isolation check needs a positive control. A test that cannot fail is not a test.
- The prototype repository, as a reference to read, not code to copy.

## How I checked

By running it and by trying to make it fail.

- **Design before code.** Before any YAML, the agent wrote a design sketch with two
  structurally different candidates: a Helm chart with a JSON schema, and Kustomize overlays.
  Writing the sketch surfaced a gap. Tenants could not mint a tier, but a pod could name an
  existing higher one. The build specification did not cover this.
- **Every case was seen failing for the right reason.** For each `verify.sh` case I broke the
  one thing it asserts, ran that case alone, and read the failure. Then I restored it and saw
  it pass. The table below lists each break.
- **Order independence.** On a fresh cluster I ran `escalation` first, then `network`, then
  `preemption` before `capacity`. All passed.
- **Wrong-cluster protection.** `assert_context` refused a kubeconfig whose context named
  another cluster. It also refused a second k3d cluster whose context was renamed to
  `k3d-gpu-slice`, which it caught by asking the API server for a node name.
- **A second environment.** The hosted CI runner uses a different kubectl and has 2 CPUs. It
  found a defect my laptop could not, and one intermittent failure described below.
- **Predictions before runs.** `PREDICTIONS.md` records what I expected. Two of my predictions
  were wrong, and they stay in that file as wrong.

### Every case can fail

| Case | What I broke | Result while broken |
|---|---|---|
| `quota` | Patched `research`'s quota to 5 by hand | `FAIL: expected a GPU quota refusal` and `FAIL: pod exists` |
| `capacity` | Advertised 1 GPU on the server node, outside both pools | `FAIL: no FailedScheduling event` and `FAIL: scheduled onto k3d-gpu-slice-agent-1` |
| `preemption` | Rendered `release-evals` with `tier: low` through the same chart | `FAIL: high-tier pod never Running` and `FAIL: no Preempted event` |
| `network` | Deleted `release-evals`'s NetworkPolicy | `FAIL: expected curl exit 7 in under 5s`. The positive controls still passed |
| `overflow` | Advertised 2 GPUs on the server node | `FAIL: split was datacenter=4 cloud=1 (of 6)` |
| `overflow` | Changed the fixture team's `computePool` from `datacenter` to `any` | `FAIL: pinned pod landed on k3d-gpu-slice-agent-1` |
| `escalation` | Deleted `research`'s RoleBinding | `FAIL: list pods in own namespace` and `FAIL: own tier refused`. The denials that follow correctly report that RBAC, not the policy, refused them |
| `escalation` | Deleted the `tenant-entitlement` policy binding | `FAIL: not denied by the entitlement policy`, and nothing else |
| `escalation` | Removed the Pod Security label from `research` | `FAIL: not denied by Pod Security`, and nothing else |

My first breaks for `capacity` and `overflow` changed the GPU count on a pool node. The
`check_fleet` guard at the start of `verify.sh` stopped both runs before the case started. That
proved the guard works, not the case, so I chose breaks that leave the pools at 4 and 4.

## What went wrong in this repository

| Defect | How it surfaced | What changed |
|---|---|---|
| **A fallback that could never run.** `lib.sh` wraps `helm` in a function that falls back to a pinned Docker image. The first draft tested `command -v helm`, which inside a function named `helm` finds the function itself. The fallback never fired, and a machine without Helm would fail | I ran `make render` with Helm removed from `PATH`: `helm: command not found`. It is the same defect as one in the prototype (a fallback that cannot trigger), repeated in new code | Use `type -P helm`, which finds only files on `PATH` |
| **An assertion that counted the wrong thing.** Case `overflow` computed pods on cloud as "6 minus pods on datacenter". A pod on any other node counted as cloud | Breaking the case: with 2 GPUs on the server node, one pod spilled there. The new count reported `cloud=1`. The old arithmetic would have reported `cloud=2` and passed | Count each pool by its node name |
| **A failure message that claimed a security hole.** When RBAC refused every pod, case `escalation` reported `tenant could claim tier high`. In fact the tenant could create nothing | Breaking the case by deleting the RoleBinding | Failure messages now say which check did not fire, and the response is printed above them. This is the same class as the `auth can-i` defect below: a check that fails in the alarming direction |
| **A flag my kubectl accepted and CI's did not.** `kubectl get nodes -L ... -o custom-columns=...` works on my kubectl 1.35 and is rejected on the runner | The first CI run: `--label-columns option cannot be used with custom-columns` | Dropped `-L`. The label was already a column |
| **Reading a field before it existed.** `create.sh` printed `allocatable` right after patching `capacity` and showed `<none>` | The first `create` output | Wait until the kubelet copies the value into `allocatable`, which is the field the scheduler reads |
| **Garbled logic in a retry loop.** The first draft of the network case's retry compared two string expansions that did not test anything | Reading the draft before running it | Replaced with a `got_200` helper |
| **A commit with the wrong author email.** The agent overrode my configured noreply address with my personal one | GitHub refused the push under its email privacy setting | Amended the commit to use the configured identity |

## Claims in my own inputs that measurement corrected

Three things in the documents I handed the agent were wrong. Each was caught by running
something, not by reading.

- **"The starved tenant must be research, because a high-tier pod would preempt instead of
  waiting."** In case `capacity`, every GPU is held by high-tier pods, so a high-tier requester
  finds no lower-priority victim and waits too. The scheduler said so:
  `No preemption victims found for incoming pod`. Research is still the right choice, because a
  low-tier pod can never preempt, whoever holds the fleet.
- **"The pinned pod fails on node affinity rather than `Insufficient nvidia.com/gpu`."** The
  scheduler reports one reason per node, so the message contains both.
- **"The node grace period is 40 seconds."** It has been 50 seconds since Kubernetes 1.32, and
  this cluster runs 1.35. Research with a citation caught it. `production-design.md` now says 50.

## A suggestion I evaluated and rejected

**Inject the tier instead of validating it.** The obvious way to spare teams from writing
`priorityClassName` is a MutatingAdmissionPolicy that fills it in from the namespace. I rejected
it for the slice. On Kubernetes 1.35 that API is not enabled by default, so k3s would need extra
API server flags. It also means a component that silently rewrites tenant pods, and a mutation
bug there could grant a tier. The slice validates and states the cost to teams in
`CONTRACT.md`. Production would inject, with the validating policy kept behind it as a backstop.

The prototype also produced an earlier rejection. A test framework's `skipDelete` option would
have let each test reuse the previous test's fixtures. Measured, it saved about 8.7s of a 63s
run and could not touch cluster creation. It also made test 2 pass only because test 1 had run
first. I kept per-case setup and teardown, because a reviewer will ask for one case, not all.

## The prototype

Before this repository, a throwaway prototype measured the approach on a laptop, a hosted CI
runner, and a second Linux machine. Its defects shaped the checks here:

- **A check that reported a security hole that did not exist.** `kubectl auth can-i` exits 1
  when the answer is "no". Under `pipefail`, a correct RBAC denial became a script failure:
  `FAIL: CAN patch own quota - self-escalation open`. Running the command by hand returned `no`.
  The check failed in the direction that looks like diligence. `verify.sh` captures the printed
  answer and compares strings.
- **A suite that could have run against the wrong cluster.** The second machine's `kubectl` was
  a symlink to `k3s`, which defaults to a different, live cluster. Only a root-only file
  permission stopped it. `ARCHITECTURE.md` tells the full story. It is why `assert_context`
  exists.
- **Manifests that were right one at a time and wrong together.** Three tenants' YAML was joined
  without `---`, so each NetworkPolicy merged into the next team's Namespace. The slice renders
  each team separately through one chart.
- **An estimate that measurement replaced.** I estimated CI at 2 to 5 minutes per run. It was 72
  seconds.

## The rule I work by

Generated code is a draft written in a confident tone. In this repository, two of the defects
above would have shipped: one as a check that passes for the wrong reason, one as a false
alarm. Breaking each test on purpose found both. Neither would have shown up in a green run.
