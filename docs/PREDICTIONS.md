# Predictions

Each prediction below was written before its check ran. It names the mechanism it rests on and
the exact string that would confirm it. A prediction that turned out wrong stays in this file and
moves to [the last section](#predictions-that-were-wrong). It is not edited to match.

The reason for this file is that a check can pass for the wrong reason. Naming the expected
artifact in advance (the event, the message, the exit code) separates "it went green" from "the
platform did what I said it would". `verify.sh` prints the same predictions as `EXPECT:` lines
before each case runs.

Each row is marked:

- **[M]** confirmed by measurement. The case name says which `verify.sh` case shows it.
- **[H]** measured on the earlier throwaway prototype, not re-run on this slice.
- **[P]** a prediction only. Nothing in the slice exercises it yet.

## 1. Tenant boundaries

| Team | `gpuCap` | `tier` (renders to) | `computePool` |
|---|---:|---|---|
| `research` | 4 | `low` (`tenant-low`) | `any` |
| `release-evals` | 6 | `high` (`tenant-high`) | `any` |
| `inference-eval` | 4 | `high` (`tenant-high`) | `any` |

The caps sum to 14 against 8 advertised GPUs (4 per node, two nodes), so contention comes from
the entitlements themselves and needs no special setup. `inference-eval` has the same cap as
`research` and the opposite tier. Cap size and priority are independent knobs, and the third
team exists to prove the code path handles a combination the first two do not.

| # | Action | Prediction | Mechanism | Confirming artifact |
|---|---|---|---|---|
| 1 | `research` submits a pod that requests 5 GPUs (cap 4) | Refused at admission. The pod is never created | `ResourceQuota` is an admission check on `requests.nvidia.com/gpu` and runs before the object exists | The error contains both `exceeded quota` and `nvidia.com/gpu`, and `get pod` returns `NotFound`. **[M]** `quota` |
| 2 | `release-evals` holds 6 and `inference-eval` holds 2, so high tier holds all 8. `research` (low tier, 0 of 4 used) requests 1 | Admitted, then `Pending` | A cap is a ceiling, not capacity set aside. Admission and scheduling are separate stages | A `FailedScheduling` event on that pod containing `Insufficient nvidia.com/gpu`. **[M]** `capacity` |
| 2a | Same as #2, but `inference-eval` (high tier) is the one requesting | ~~It preempts instead of waiting~~ | | Wrong. See [predictions that were wrong](#predictions-that-were-wrong). **[M]** |
| 3 | Same as #2, but asserting only `Pending` | Would pass for the wrong reason. An image-pull failure is also `Pending` | | This is why #2 asserts the event message, not the phase. **[M]** |
| 4 | `research-sa` lists pods in `research` | Allowed | The RoleBinding grants `list` on pods in that namespace only | `kubectl auth can-i` prints exactly `yes`. **[M]** `escalation` |
| 5 | `research-sa` lists pods in `release-evals` | Denied | No binding for that identity in that namespace, and no cluster-wide grant | Prints exactly `no`, and exits 1. Piping it under `pipefail` turns a correct denial into a script failure. **[M]** `escalation` |
| 6 | `research-sa` patches its own `ResourceQuota` | Denied | The tenant Role gives read-only access to `resourcequotas` | Prints `no`. This is the proof at the API layer. CODEOWNERS alone would guard only the documented path. **[M]** `escalation` |
| 7 | `research-sa` creates a `PriorityClass` | Denied | `PriorityClass` is cluster-scoped, and the tenant holds namespaced Roles only | Prints `no`. **[M]** `escalation` |
| 7a | `research-sa` patches its own namespace, where the entitlement labels live | Denied | The tenant Role has no verbs on `namespaces` | Prints `no`. **[M]** `escalation` |
| 7b | `research-sa` creates a pod that names `tenant-high` | Refused at admission by policy `tenant-entitlement` | The policy compares `priorityClassName` with the namespace's `priority-class` label. Denying `create priorityclass` stops minting a tier, not borrowing one | `tenant research is entitled to priorityClassName tenant-low, pod asked for tenant-high`. A `tenant-low` pod from the same identity is accepted, which proves the refusal is the policy and not RBAC. **[M]** `escalation` |
| 7c | `research-sa` creates a privileged pod | Refused by Pod Security | Tenant namespaces enforce `baseline` | `violates PodSecurity "baseline:latest": privileged`. **[M]** `escalation` |

## 2. Network isolation

| # | Action | Prediction | Mechanism | Confirming artifact |
|---|---|---|---|---|
| 8 | A pod in `release-evals` curls `target.release-evals` | Reaches it. This is the positive control | The NetworkPolicy admits ingress from `podSelector: {}`, meaning pods in the same namespace | HTTP 200, before and after #9. If this fails, the isolation result means nothing. **[M]** `network` |
| 9 | A pod in `research` curls `target.release-evals` | Blocked | Default-deny ingress with a same-namespace allow rule. k3s enforces standard NetworkPolicy | curl exits 7 within about a second, not 28 (timeout). k3s refuses the connection instead of dropping it. **[M]** `network` |
| 10 | Same as #9, but the target pod is not yet Ready | Would fail exactly like #9 and look like working isolation | A probe failing on DNS or missing endpoints looks the same as one blocked by policy | This is why #8 runs in the same pass, and why the case fails if the control never answers. **[M]** `network` |

## 3. Priority under contention

| # | Action | Prediction | Mechanism | Confirming artifact |
|---|---|---|---|---|
| 11 | 4 low-tier `research` pods and 4 high-tier `release-evals` pods hold all 8 GPUs. `release-evals` requests 1 more | Preemption. A `research` pod is evicted and the high-tier pod runs | `tenant-high` has `preemptionPolicy: PreemptLowerPriority`, and the scheduler frees the smallest set of lower-priority pods that makes room | A `Preempted` event on one of this run's `research` pods, matched by pod UID, and the preemptor reaching Ready. **[M]** `preemption` |
| 12 | Same as #11, asserting `status: Evicted` on the victim | Would be unsound. An OOM kill, a node loss, and a manual deletion leave the same status | | Assert the event, never the status. **[M]** |
| 12a | Same as #11, matching any `Preempted` event in the namespace | Could pass on a previous run's event. Events outlive their pods by an hour | | This is why the case matches events by the UIDs of the pods it just created. **[M]** |
| 13 | A `research` pod inside its cap while high tier holds all capacity | Waits indefinitely, which is the intended behaviour. The platform enforces caps at admission and makes no promise of availability | The caps are set above the hardware on purpose | `Insufficient nvidia.com/gpu`, and a contract that says so (`CONTRACT.md`). **[M]** `capacity` shows the wait. "Indefinitely" is a property of the design and was not timed |
| 13a | `inference-eval` (cap 4, high) contends with `research` (cap 4, low) on a full fleet | `inference-eval` wins despite the identical cap | Under contention the tier decides. The cap only bounds how much a team may hold | `inference-eval` pod Running and a `Preempted` event on a `research` pod. **[M]** measured by hand with the `verify.sh` helpers |

## 4. Compute pools and overflow

The two agent nodes are labelled `platform.example.com/compute-pool=datacenter` and `=cloud`,
with 4 fake GPUs each. The spec field `computePool` is `any`, `datacenter`, or `cloud`.

| # | Action | Prediction | Mechanism | Confirming artifact |
|---|---|---|---|---|
| 20 | `release-evals` (`any`, prefers datacenter) submits 6 pods of 1 GPU | The first 4 land on the datacenter node, and the next 2 spill to cloud | `preferredDuringSchedulingIgnoredDuringExecution` with weight 100 favours datacenter and does not forbid cloud | `kubectl get pods -o wide` shows 4 on `agent-0` and 2 on `agent-1`, each pool counted by node name. **[M]** `overflow` |
| 21 | A team pinned with `computePool: datacenter` submits 1 pod while the datacenter node is full | `Pending`. It does not spill | The pin renders a required `nodeSelector`. No node satisfies both it and the GPU request | A `FailedScheduling` event containing `didn't match Pod's node affinity/selector`, and an empty `spec.nodeName`. **[M]** `overflow`. The message also contains `Insufficient nvidia.com/gpu`, which I did not predict |
| 21a | The pinned team submits a pod without the `nodeSelector` | Refused at admission | Policy `tenant-entitlement` requires a pinned team's pods to carry the pool selector | `tenant dc-pinned is pinned to compute pool datacenter, pod must set nodeSelector ...`. **[M]** `overflow` |
| 22 | #20 and #21 side by side | Two team intents, one field. "Prefer the datacenter, accept cloud" and "datacenter only" are both legitimate and both expressible | Preferred affinity against a required selector | The spec states intent, not scheduler syntax. **[M]** `overflow` |

## 5. When a GPU node disappears

Measured on 29 September 2026 on clusters built like this slice, with the timers shortened:
`node-monitor-grace-period=20s` on the controller manager, and
`default-not-ready-toleration-seconds=20` plus `default-unreachable-toleration-seconds=20` on the
API server. The defaults are 50s and 300s. No `verify.sh` case stops a node.
[`ARCHITECTURE.md`](ARCHITECTURE.md#reproduce-the-node-loss-measurement) has the commands. The
workload was a `research` Deployment on the datacenter node, at the team's cap of 4.

| # | Action | Prediction | Mechanism | Confirming artifact |
|---|---|---|---|---|
| 14 | Stop the datacenter node | `Ready` becomes `Unknown` and the node is tainted `unreachable` within the grace period | The node lifecycle controller waits out the grace period after the last heartbeat, then taints | Taint `node.kubernetes.io/unreachable` at t+14s to t+20s across three runs. **[M]** |
| 15 | Read `.status.capacity` while the node is unreachable | Unchanged. Scheduling stops because of the taint and `NotReady`, not because capacity became 0 | Nothing zeroes node status when the kubelet goes silent | `nvidia.com/gpu: 4` throughout. Say "the scheduler stops placing pods there", never "capacity goes to zero". **[M]** |
| 15a | Read a pod's tolerations | Two `NoExecute` tolerations, `not-ready` and `unreachable`, each with the API server's default seconds | The `DefaultTolerationSeconds` admission plugin adds them when the pod is created | `node.kubernetes.io/unreachable NoExecute 20`. With only the not-ready flag set, the same pod carried `unreachable NoExecute 300`. **[M]** |
| 16 | Wait past the toleration window, pods with a 0-second grace period | Evicted, and the Deployment's replacements run on the cloud node | The `unreachable` toleration expires. Preferred affinity lets the replacements spill | Replacements Running at t+38s. The bare pod was not replaced. With only the not-ready timer shortened, eviction came at t+315s. **[M]** |
| 16a | Same, pods with a 30-second grace period, team at its cap | ~~Replacements are admitted once the grace period passes~~ | | Wrong. See [predictions that were wrong](#predictions-that-were-wrong). **[M]** |
| 16b | Taint the dead node `node.kubernetes.io/out-of-service=nodeshutdown:NoExecute` | The stuck pods are force-deleted, quota is released, and the replacements run | The pod garbage collector force-deletes pods on an out-of-service node | Stuck pods gone within 15s, 4 replacements Running on the cloud node at 16s. **[M]** |
| 17 | Restart the same node | The fake GPU capacity survives | The capacity lives on the Node object, not in the kubelet, and a restart keeps the object | Same Node UID, `nvidia.com/gpu: 4`. **[M]** |
| 18 | Delete the Node object and let the kubelet register again | The capacity is lost | A new Node object has no extended resources | New UID, the pool label back (k3s sets it at registration), no `nvidia.com/gpu`. Running `create.sh` again restored `4`. **[M]** |
| 19 | Add a brand-new node | No GPU capacity on it | Same as #18 | Not re-run on this slice. **[H]** |

Rows 17 and 18 together are the answer to "what happens when a GPU node disappears". The patch
survives a restart but not a replacement. That is why production advertises through a device
plugin: a DaemonSet re-advertises on every kubelet start, which covers both. Rows 16a and 16b are
the part I did not predict.

## 6. Changes a panel may ask for live

These are predictions for the extension round. Rows marked [M] were observed while proving that
each `verify.sh` case can fail.

| Change | Prediction | Why |
|---|---|---|
| Raise the `research` cap from 4 to 8 | Existing `Pending` pods do not start. **[P]** | Quota was never the limit. Capacity was, and raising a ceiling does not add hardware |
| Raise the `research` quota to 5 by hand | Case `quota` fails: the 5-GPU pod is created. **[M]** | This is also why a hand edit is drift, and why tenants cannot patch their quota |
| Lower the `release-evals` cap from 6 to 2 while it holds 6 | Running pods are not evicted. New pods are refused until usage drops below 2. **[P]** | Quota is enforced at admission. It does not reclaim |
| Give every team `tier: high` | Preemption stops settling contention. Every waiting pod waits in creation order. **[P]** | Priority only works as a relative order. Measured #2a already shows a high-tier pod waiting when every holder is also high |
| Change `release-evals` to `tier: low` | Case `preemption` fails: the preemptor never runs and nothing is preempted. **[M]** | Equal priority means no victims |
| Onboard a fourth team | One spec file, the same code path, no chart change. **[M]** `overflow` onboards `dc-pinned` this way | The chart renders every object from one spec |
| Flip a team from `any` to `datacenter` | Running pods stay where they are. Only new pods are constrained. **[P]** | Affinity is `IgnoredDuringExecution`, and the policy checks `CREATE` only |
| Flip the `dc-pinned` fixture from `datacenter` to `any` | Case `overflow` fails: the pod spills to cloud. **[M]** | Preferred affinity allows cloud |
| Stop the datacenter node while an `any` team has pods on it | Pods are evicted and reschedule onto cloud. **[P]** | The preference cannot be met, but nothing forbids cloud |
| Same, but the team is pinned to `datacenter` | Pods are evicted and stay `Pending` until the node returns. **[P]** | A hard constraint outlives the node |
| Delete a team's NetworkPolicy | Cross-tenant traffic succeeds at once. **[M]** RBAC is unaffected. **[P]** | Network and RBAC are separate layers. Losing one does not lose the other |
| Delete the `tenant-entitlement` policy binding | A tenant can create a pod at a tier it does not have. **[M]** | The policy is the only thing between a pod spec and a borrowed tier |

## Predictions that were wrong

Kept on purpose. A predictions file with no misses was written afterwards.

| I predicted | What happened | Why I was wrong |
|---|---|---|
| A CI round-trip would cost 2 to 5 minutes, too slow for iteration | 72 seconds end to end on the prototype, slightly faster than a cold local run | I estimated instead of measuring. The conclusion survived on a different basis: a hosted runner cannot stay warm. The stated reason was wrong |
| Fake GPU capacity would not survive a node restart | It survives a restart and is lost only when the Node object is replaced | I treated "the kubelet restarted" and "the Node object was recreated" as the same event. The corrected version explains why a device plugin is a DaemonSet |
| `--skip-delete` in the test framework would make the suite much faster | It saves about 8.7s of a 63s run and cannot touch the 24s cluster creation | I reasoned about the flag's purpose instead of measuring its reach |
| #2a: in case `capacity`, a high-tier requester would preempt instead of waiting, so using `inference-eval` there "would prove the opposite" | It waits too: `No preemption victims found for incoming pod`. Every holder is also high tier, and preemption needs a strictly lower-priority victim | I reasoned from "high tier preempts" without checking who held the GPUs. `research` is still the right requester, for a sturdier reason: a low-tier pod can never preempt, so the case holds whoever holds the fleet |
| #21: the pinned pod's `FailedScheduling` message would cite node affinity "rather than" `Insufficient nvidia.com/gpu` | It cites both: `1 Insufficient nvidia.com/gpu, 2 node(s) didn't match Pod's node affinity/selector` | The scheduler reports one reason per node. The datacenter node lacks GPUs and the other two fail the selector. The assertion checks for the affinity reason and for an empty `nodeName`, which is what separates the two failure modes |
| #16a: once an evicted pod's grace period passed, quota would stop counting it, so a team's replacements would be admitted. `ARCHITECTURE.md` said so, marked as unmeasured | The evicted pods stayed `Terminating` for as long as the node was down, quota kept counting them, and every replacement was refused with `exceeded quota`. The `out-of-service` taint released them | I reasoned from how the quota code treats a pod past its deletion time, instead of measuring. I did not dig into why usage stayed at 4. The out-of-service taint is the fix either way, and measuring took one run |
| The prototype's node-loss notes were complete | They named only `default-not-ready-toleration-seconds`. A stopped node is `unreachable`, and with only that flag set, eviction took 315s, not 38s | The notes recorded the flag I thought mattered, not the flags the run used. A live demo following the notes would have waited five minutes |
| The first `advertise_fake_gpus` would show `nvidia.com/gpu: 4` right after the patch | It showed `<none>` in `allocatable` for a few seconds | The patch sets `capacity`. The kubelet copies it into `allocatable`, which is what the scheduler reads, on its next status sync. `create.sh` now waits for `allocatable` |
