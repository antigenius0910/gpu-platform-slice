# Platform contract

This is the agreement between the platform team and the teams that run GPU work on it. It says
who owns what, where the line between them is, and what each side can expect when something is
refused, delayed, or changed. Every message quoted below is copied from a real run of
`slice/verify.sh`.

A GPU cap is a ceiling on what a team may hold at one time. It is not capacity set aside for
that team. The caps add up to 14 GPUs on a fleet of 8, so a team inside its cap can wait,
and a low-tier team can wait indefinitely.

## What the platform owns

- The clusters and nodes, and the GPU capacity each node advertises.
- The tiers: the PriorityClasses `tenant-low` and `tenant-high`, and the map from a spec's
  `tier` to a class.
- The tenant chart (`slice/chart/`), which is the only code path from a spec to cluster
  objects. It owns the namespace, ServiceAccount, Role, RoleBinding, ResourceQuota, and
  NetworkPolicy of every team.
- The cluster-wide admission rules: the `tenant-entitlement` policy and Pod Security
  `baseline` on every tenant namespace.
- Approval of every entitlement change (see [the seam](#the-seam)).
- Detection of a lost node and rescheduling of the work that was on it.
- The verification suite, and keeping it green after every platform change.

## What teams control

- Everything inside their own namespace that the `tenant-developer` Role allows: pods,
  deployments, jobs, services, config maps, and secrets.
- How they spend their cap: how many pods, how many GPUs per pod, and which work goes first.
- Their placement intent, stated once in the spec: `any` (prefer the datacenter, spill to
  cloud) or a pinned pool that never spills.
- Checkpointing. The platform restarts work after a node loss or a preemption. It does not
  save progress.
- Proposing changes to their own entitlement, by opening a pull request.

Teams can read their quota and the events on their own pods, so they can diagnose a refusal or
a wait without asking the platform team.

## The seam

The seam is one file per team: `slice/tenants/<team>.yaml`. It states entitlement, not
Kubernetes objects:

```yaml
name: research
gpuCap: 4
tier: low
computePool: any
networkIsolation: namespace
```

A team proposes. The platform approves. `.github/CODEOWNERS` assigns `slice/tenants/`,
`slice/chart/`, and `slice/platform/` to the platform team, so any change to an entitlement,
to how entitlements render, or to the cluster-wide rules needs a platform approval.

| Change | Who proposes | Who approves |
|---|---|---|
| Onboard a team | The team | Platform team |
| Raise or lower `gpuCap` | The team | Platform team, as the owner of fleet capacity |
| Change `tier` | The team | Platform team. A move to `high` lowers every low-tier team's odds, so it is a fleet decision, not a team decision |
| Change `computePool` | The team | Platform team |
| Add a field or a new allowed value | Platform team | Platform team, with a new verify case |
| Workloads inside the namespace | The team | Nobody. The cap, the tier, and admission bound them |

The seam holds at two layers. In Git, CODEOWNERS decides who reviews an entitlement change.
In the API server, the tenant's identity cannot change its entitlement at all: case
`escalation` asserts that `research-sa` cannot patch its quota, cannot patch its namespace
labels, cannot create a PriorityClass, and cannot create a pod that names a higher tier. A
Git control alone would prove only that the documented path is guarded.

## How invalid and queued requests are explained

Every refusal names the rule that refused it, and every wait names its reason. The team sees
both through the same `kubectl` it already uses.

| Situation | Where the team sees it | What it says |
|---|---|---|
| A spec with an unknown tier | `make render`, in the pull request's CI | `tier: tier must be one of the following: "low", "high"` |
| A spec that tries to name a PriorityClass | `make render` | `(root): Additional property priorityClass is not allowed` |
| A pod over the cap | Refused when created | `exceeded quota: gpu-cap, requested: requests.nvidia.com/gpu=5, used: requests.nvidia.com/gpu=0, limited: requests.nvidia.com/gpu=4` |
| A pod naming a tier the team does not have | Refused when created | `tenant research is entitled to priorityClassName tenant-low, pod asked for tenant-high. Tier changes are a PR to slice/tenants/research.yaml` |
| A pinned team's pod without its pool | Refused when created | `tenant dc-pinned is pinned to compute pool datacenter, pod must set nodeSelector platform.example.com/compute-pool=datacenter (got <none>)` |
| A privileged pod | Refused when created | `violates PodSecurity "baseline:latest": privileged (container "work" must not set securityContext.privileged=true)` |
| Inside the cap, but no free GPU | Pod is `Pending`. `FailedScheduling` event on the pod | `0/3 nodes are available: 3 Insufficient nvidia.com/gpu.` followed by `No preemption victims found for incoming pod` |
| Pinned pool is full | Pod is `Pending`. `FailedScheduling` event | `1 Insufficient nvidia.com/gpu, 2 node(s) didn't match Pod's node affinity/selector` |
| Preempted by a higher tier | `Preempted` event on the evicted pod | `Preempted by pod <uid> on node k3d-gpu-slice-agent-0` |

Two gaps remain. A `Pending` pod has a reason but no position in a queue and no estimate, and
nothing escalates a wait that has gone on too long. Both need a queue such as Kueue. Until then,
the contract for a long wait is to ask the platform team, who can see the whole fleet.

## How exceptions become reusable capabilities

A request that the spec cannot express is an exception. The platform does not grant it with a
hand edit in the cluster. A hand edit is invisible to the next reviewer, is undone by the next
`create.sh`, and helps only one team. Instead, each exception goes through three steps:

1. **Check whether an existing value already covers it.** Many requests do. A team that says
   "our data must stay in the datacenter" needs `computePool: datacenter`, which already exists.
2. **Otherwise, add it to the schema as a value any team can request.** The change is a
   pull request to `values.schema.json`, the chart template that renders the new value, and a
   verify case that proves it. The team that asked is the first user.
3. **Approve its use per team through the seam**, the same as any other entitlement change.

For example, suppose `release-evals` needs to call a model server in `research`. Today
`networkIsolation` has one value, `namespace`, which admits ingress from the same namespace only.
The exception becomes a new capability, `allowIngressFrom: [release-evals]` on the `research`
spec. The chart renders one extra ingress rule from that namespace. A new verify case asserts
that `release-evals` gets through and that `inference-eval` is still refused. After that, any
pair of teams can ask for the same thing, and the reviewer sees exactly who can reach whom in
the spec files.

The pinned pool is the example that already happened. `computePool: datacenter` renders a
required `nodeSelector`, the `tenant-entitlement` policy enforces it, and case `overflow` proves
it with a fourth team onboarded through the same chart. No team-specific code was added.

## How a policy change reaches existing tenants, and how partial failure is found and fixed

### How a change reaches tenants

In the slice, every team renders from one chart, so a chart change reaches every team the next
time `create.sh` runs its apply loop. Cluster-wide objects, the PriorityClasses and the
`tenant-entitlement` policy, change for everyone at the moment they are applied.

A policy change applies to new requests, not to work that is already running:

- Lowering a cap does not evict running pods. ResourceQuota checks at admission, so the team's
  new pods are refused until its usage drops under the new cap.
- Changing a pool does not move running pods. Node affinity is `IgnoredDuringExecution`.
- The `tenant-entitlement` policy checks pod `CREATE` only, so a stricter rule leaves running
  pods alone.

This is deliberate. The platform does not stop work to enforce a new rule. If a change must
apply to running work, the platform team drains that team's pods as a separate, announced step.

In production, the chart is versioned and each cluster pins a version. A change therefore
reaches nobody until a cluster's pin is bumped, and the bumps are the rollout: first one canary
team, then one cluster, then the rest, with `verify.sh` run against the canary after each step.
A new admission rule starts with `validationActions: [Warn, Audit]`. For a week, the platform
sees which teams' pods would be denied, and those teams see a warning on each request. Then it
switches to `Deny`.

### How partial failure is detected

- `create.sh` runs with `set -e` and applies teams one at a time. If a team's apply fails, the
  script stops. Teams before it have the new version and teams after it have the old one.
  The failing step is the last line of output.
- `kubectl diff -f <rendered team>` exits non-zero for any team whose live objects differ from
  its spec. That finds a team that was skipped, and it also finds a hand edit.
- `verify.sh` checks the behaviour, not the objects. A change that applies cleanly but breaks
  isolation or preemption fails a case.
- In production, a reconciler reports a sync status per team and per cluster, and an alert fires
  on any team that stays out of sync.

### How it is fixed

Every step converges on the state in Git, so the first fix for a partial failure is always to
fix the cause and run `create.sh` again. Teams that already have the new version are unchanged
by the second run. To roll back, revert the commit and run `create.sh`. In production, revert
the pin bump. A failed cluster stays on its old version while the rest proceed, which is safe
because a chart version must work for every team on the previous version too.

## What this costs teams

- **Waiting with no promise.** Inside its cap, a low-tier team can wait indefinitely while
  high-tier teams hold the fleet. Case `capacity` shows this with `research` using 0 of its 4
  GPUs.
- **Preemption at any time for low tier.** A low-tier pod can be evicted to make room for a
  high-tier pod. Long low-tier jobs must checkpoint and tolerate a restart.
- **Two lines in every pod.** Pods must set `priorityClassName` to their tier's class, and a
  pinned team's pods must also set the pool's `nodeSelector`. The platform validates these
  fields and does not fill them in. Production would inject them, and the cost would drop to
  zero.
- **A review for every entitlement change.** More GPUs, a higher tier, or a new pool is a pull
  request and a platform review. It is not self-service in the moment.
- **Same-namespace traffic only.** A team that needs another team's service must request the
  capability first.
- **No privileged pods.** Pod Security `baseline` blocks privileged containers and `hostPath`.
  Some GPU debugging tools need them, and they belong to the platform team, not to tenants.
