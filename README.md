# GPU platform slice

A small, runnable self-service GPU platform. Onboarding a team is a five-line file in Git. The
platform then enforces the team's isolation, its GPU cap, and its priority when GPUs run out.
It runs on a local k3d cluster with fake GPUs, so it needs no GPU and no cloud account.

The oversubscription, in four lines:

```text
research         gpuCap 4   tier low    pool any
release-evals    gpuCap 6   tier high   pool any
inference-eval   gpuCap 4   tier high   pool any
caps 4 + 6 + 4 = 14 GPUs  >  8 GPUs in the fleet (4 datacenter + 4 cloud)
```

A cap is a ceiling, not capacity set aside. Every team can be inside its cap while some of its
pods wait.

## Run it

You need Docker, [k3d](https://k3d.io) 5.8 or later, and kubectl 1.34 to 1.36. Helm is
optional: if it is not installed, the scripts run a pinned Helm image in Docker. Nothing reads
or changes your default kubeconfig.

```sh
cd slice
make create      # about 40s cold: cluster, fake GPUs, platform objects, three teams
make verify      # about 60s: all six cases, each prints EXPECT: before it runs
make destroy     # deletes the cluster and its kubeconfig
```

To run one case, alone and in any order:

```sh
make verify CASE=network
./verify.sh quota escalation
```

The cases are `quota`, `capacity`, `preemption`, `network`, `overflow`, and `escalation`.
Every case prints its prediction, then the evidence (the refusal text, the event message, the
curl exit code), then `PASS` or `FAIL`. The same `verify.sh` runs in CI on every push that
touches `slice/`: see the `verify` workflow under the Actions tab.

## What the verification proves

| Case | Claim | Evidence it asserts |
|---|---|---|
| `quota` | A request over the cap is refused at admission | The error names both `exceeded quota` and `nvidia.com/gpu`, and the pod never exists |
| `capacity` | A request inside the cap can still wait | `research` (0 of 4 used) is admitted, then a `FailedScheduling` event says `Insufficient nvidia.com/gpu` |
| `preemption` | The higher tier wins when GPUs run out | A `Preempted` event on one of this run's low-tier pods, and the high-tier pod running |
| `network` | Team A cannot reach team B's service | A same-namespace probe gets HTTP 200 before and after. The cross-team probe gets curl exit 7 |
| `overflow` | `any` spills to cloud; a pinned team does not | 4 pods on the datacenter node and 2 on cloud. A pinned pod stays `Pending` citing node affinity, and a pinned pod without its pool is refused |
| `escalation` | A team cannot grant itself more | As `system:serviceaccount:research:research-sa`: it can list its own pods. It cannot read another team's pods, patch its quota or namespace, create a PriorityClass, name a higher tier on a pod, or run a privileged pod |

Each case was also broken on purpose and seen failing for the right reason. See
[`docs/NOTES.md`](docs/NOTES.md#every-case-can-fail).

## Map of the repository

```text
README.md                    this file
slice/                       everything that runs
  Makefile                   create | verify [CASE=] | destroy | render
  create.sh verify.sh destroy.sh lib.sh
  tenants/*.yaml             one entitlement file per team, the only file a team edits
  chart/                     Helm chart: tenant spec -> namespace, RBAC, quota, policy
  platform/                  PriorityClasses and the tenant-entitlement admission policy
  fixtures/dc-pinned.yaml    a fourth team that case overflow onboards and removes
docs/
  ARCHITECTURE.md            diagram, production mapping, what the toy hides, node loss,
                             trust assumptions, and what the design makes worse
  CONTRACT.md                what teams control, what the platform owns, the seam
  PREDICTIONS.md             predicted outcome and expected string per case, and the misses
  NOTES.md                   how AI was used, how it was checked, what it got wrong
  production-design.md       the full production platform this slice stands for
  diagrams/                  architecture.mmd and its rendered SVG
.github/CODEOWNERS           platform approval on tenants/, chart/, platform/
.github/workflows/verify.yml create, verify, destroy on a hosted runner
```

## Design in brief

A team's file states entitlement in abstract terms: `tier: low`, not a PriorityClass name. One
Helm chart renders every team, and its JSON schema rejects a bad spec before the cluster sees
it. The cluster enforces each entitlement at admission. ResourceQuota enforces the cap. A
ValidatingAdmissionPolicy makes each pod use its team's tier and pinned pool. Pod Security
`baseline` blocks privileged pods. RBAC stops a team from editing any of them. CODEOWNERS
routes every entitlement change to the platform team. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
explains why each boundary sits where it does.

Traefik and ServiceLB are disabled in the k3d cluster. Nothing in the slice needs ingress or a
LoadBalancer, and ServiceLB would bind host ports on the reviewer's machine.

## Time spent

TIME-SPENT-TBD

## What I left out on purpose

- **Real GPU software.** No device plugin, GPU Operator, MIG, or time-slicing. They need real
  hardware. The slice writes `nvidia.com/gpu: 4` onto each node's status instead.
- **Cloud and bare-metal provisioning.** No Terraform, EKS, Karpenter, or Cluster API. One
  local cluster with two labelled node pools stands in for two fleets. The brief permits
  manifests plus scripts, and wrapping k3d in Terraform would add a dependency and buy nothing.
- **A second cluster.** Cross-cluster overflow and Cilium ClusterMesh are design, in
  `docs/production-design.md`.
- **A controller.** At three teams, a chart and `kubectl apply` are enough. A reconciler earns
  its place at around fifty teams, where drift and fan-out matter.
- **Injection of the tier and pool into pods.** The admission policy validates. It does not
  mutate, so pods state both fields. `docs/CONTRACT.md` lists this as a cost to teams.
- **Egress isolation, fair share within a tier, and job queueing.** Each is a real production
  need and is named in `docs/ARCHITECTURE.md`. None was needed to prove the brief's boundaries.
- **Node loss as a `verify.sh` case.** Stopping a node takes a minute and changes the cluster
  for every case after it. It was measured on this slice instead, and `docs/ARCHITECTURE.md` has
  the results and the commands to reproduce them.
- **Dashboards and extra pools.** The brief gives them no credit.

## The next thing I would check

Why a k3s node sometimes fails on the hosted CI runner. In 2 of the first 6 runs, one node never
became Ready or went silent shortly after, and the readiness gate stopped the run. The next runs
passed. Private repositories get a 2-CPU runner, and none of the other test machines ran
three k3s nodes on only 2 CPUs. The workflow now
records node conditions, memory, inotify limits, and each node's k3s log when a step fails. The
next failure will show whether the node ran out of memory, hit the inotify limit, or something
else. [`docs/NOTES.md`](docs/NOTES.md#what-went-wrong-in-this-repository) has the details.
