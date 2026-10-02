# Agent rules — gpu-platform-slice

Working-tree config for the live extension. **Not part of the submission** — it is in
`.git/info/exclude`, so it never commits and never appears in `git status`.

## Hard rules

1. **NEVER push. NEVER commit to `main`.** This repo is shared with four reviewers and frozen
   at tag `submission-2026-09-30` (`03c6ec9`). Work on a local branch. Use the branch name the
   task gives you; if it gives none, use `git switch -c ext/<name>`.
2. **Commit before breaking anything.** Rehearsals showed this is the one thing that saves a live
   session. A dirty tree plus a failed experiment is unrecoverable under time pressure.
3. **Run `cd slice && make verify` after every change.** A change that breaks an existing
   guarantee is a failed extension, however good the new feature is.
4. **Prove the new check can fail.** Break what it asserts, see it go red, restore. A check that
   has never failed is not evidence.
5. **Take a baseline before your first edit.** Run `make create && make verify` on the unmodified
   branch and keep the RESULT line. **Do not edit `chart/`, `fixtures/` or `verify.sh` while a
   verify is running:** `onboard` renders the live working tree mid-run, and bash reads
   `verify.sh` as it executes.

## Commands

All scripts are **bash**. Run them as `./script.sh` or through `make`. To call a helper by hand,
use `CLUSTER=<name> bash -c 'source ./verify.sh; <helper> ...'`, never your login shell: `lib.sh`
uses `type -P`, which zsh rejects. Without `CLUSTER=` the helpers target `gpu-slice`. This is
macOS: `sed` and `grep` are the BSD versions (no `\|` alternation, `sed -i ''`); use `grep -E` and
`sed -E`.

| Command (from `slice/`) | What it does |
|---|---|
| `make create` | Creates the cluster, or converges an existing one: re-advertises GPUs, re-applies `platform/` and every `tenants/*.yaml`. **Re-run it after any chart or `platform/` edit** — `make verify` does not apply anything |
| `make verify` / `make verify CASE=<name>` | All cases, or one. Needs a running cluster (`make create` first) |
| `make render` | Validates `tenants/*.yaml` against the schema and prints `ok <spec>` per file, but no rendered YAML. It **does not check `fixtures/`**. Render a fixture, or see any output, with `helm template <name> chart -f <spec>` |
| `make destroy` | Deletes the cluster and its kubeconfig |

Scripts target the cluster named by `$CLUSTER` (default `gpu-slice`), with the kubeconfig pinned
to `~/.kube/k3d-$CLUSTER.yaml`. Any `KUBECONFIG` in your environment is ignored. Set `CLUSTER=` to
work beside another cluster. `assert_context` refuses to run against anything else.

## What this is

A multi-tenant GPU platform slice on k3d. Three tenants hold entitlements summing to 14 GPUs
against 8 advertised (4 on each of two labelled nodes), so contention is structural. The verify
cases are listed in `CASES=` at the top of `slice/verify.sh`.

## The entitlement contract — the thing not to break

`slice/tenants/*.yaml` is an **entitlement**, never a Kubernetes object:

```yaml
name: research
gpuCap: 4
tier: low                 # abstract. NOT a PriorityClass name
computePool: any          # any | datacenter | cloud
networkIsolation: namespace
```

- A PriorityClass name appears in exactly **one** place on the tenant path:
  `tenant.priorityClass` in `slice/chart/templates/_helpers.tpl`. Keep it there.
- `values.schema.json` has `additionalProperties: false`, and `values.yaml` is empty on purpose.
  A new field **must** be declared in the schema, or every render fails.
- Never leak scheduler syntax into a spec. The spec expresses intent; the chart translates.
  Resource quantities (`"8"`, `"500m"`, `"16Gi"`) are not scheduler syntax. Declare them as
  strings in the schema and quote them in specs: an unquoted `8` fails with
  `Expected: string, given: integer`.

Where everything lives:

| Path | Owns |
|---|---|
| `slice/chart/` | Everything **per tenant**: namespace and its labels, RBAC, quotas, NetworkPolicy |
| `slice/platform/` | Everything **cluster-scoped**: the PriorityClasses, and the `tenant-entitlement` ValidatingAdmissionPolicy |
| `slice/fixtures/` | Extra tenant specs that only `verify.sh` onboards (today `dc-pinned.yaml`). Same schema as `tenants/`. A fixture's filename must equal its `name:`, which is also its namespace |

The `tenant-entitlement` policy reads the namespace labels the chart writes. **Every pod in a
tenant namespace must set `priorityClassName` to its tier's class**, and a pinned team's pods must
carry the pool `nodeSelector`, or admission refuses them. `pod_yaml` and `net_pod` in `verify.sh`
do both; build test pods with them.

## Changing the entitlement — touchpoints

**Adding a field:**

1. `slice/chart/values.schema.json`: the type, and add it to `required` unless the template gives
   a default.
2. `slice/chart/templates/<resource>.yaml`: the resource that consumes it.
3. If the field is required: **every spec**, meaning all three `slice/tenants/*.yaml` **and every
   `slice/fixtures/*.yaml`**. `make render` will not catch a fixture you missed. Case `overflow`
   will, at onboarding.
4. `slice/verify.sh`: a new case proving it is enforced (see below).

**Adding a value to an existing field** (for example a new tier):

1. The enum in `values.schema.json`.
2. The map in `_helpers.tpl`, if the value maps to a Kubernetes name.
3. The cluster-scoped object it maps to, in `slice/platform/` (a new tier needs a new
   PriorityClass), then `make create`. A PriorityClass with no `preemptionPolicy` defaults to
   `PreemptLowerPriority` (today's `tenant-low` does). A class that must never preempt needs
   `preemptionPolicy: Never`. The scheduler then reports `preemption: not eligible due to
   preemptionPolicy=Never.` in the pod's `FailedScheduling` event; without `Never` the same pod
   gets `No preemption victims found for incoming pod`. For a tier at the bottom, "preempts
   nobody" is true by ordering alone, so that string is the only evidence of the policy.
4. A **fixture** spec that uses the value, onboarded inside the case. Do not move a real tenant
   onto it: the existing cases depend on the three tenants' current tiers and caps.
5. A new case. For a tier, assert its relation to **every** existing tier in both directions:
   who can preempt it, and whom it can preempt.

**Adding a quota on another resource:** put it in its own ResourceQuota and keep `gpu-cap` as it
is. The `escalation` case and the docs name `gpu-cap`, and a `can-i patch` on a renamed, missing
object still prints `no`, so a rename would pass silently. Quota `requests.*`, not `limits.*`.
Keep any default requests small (100m CPU, 128Mi or less), so the GPU cases still fail on
`nvidia.com/gpu` and not on CPU or memory. Name new per-tenant objects after what they govern: a
ResourceQuota `<what>-cap` (`gpu-cap`, `compute-cap`), a LimitRange `<what>-defaults`
(`compute-defaults`), each in a template named for its kind. Docs, `can-i` checks and break tables
quote these names, so pick them once.

**Docs are in scope.** A new case or field also updates `README.md` (the case list, table, count
and runtime), the relevant rows of `docs/CONTRACT.md` (including any quoted schema error), the
break table in `docs/NOTES.md#every-case-can-fail`, the field-to-object table in
`docs/ARCHITECTURE.md`, the tables in `docs/production-design.md`, and `docs/PREDICTIONS.md` (a
row marked `[M]` with the case name in the section it belongs to, plus a row in section 6 for each
break you ran). To find every mention:
`grep -rn '<an existing value or field name>' README.md docs`.
- If the change adds or renames a cluster object, update `docs/diagrams/architecture.mmd` and
  re-render `.svg` and `.png` with the `mermaid-cli` command at the top of `docs/ARCHITECTURE.md`.
  If you cannot render, say the diagram is stale; do not leave it silently wrong.
- `docs/production-design.md` says CPU and memory ceilings go "in the same quota". That predates
  the separate-quota rule above, and the rule wins. Rewrite that sentence if you touch quotas.
- When you quote a schema pattern or error in a markdown table, escape every `|` as `\|`, or the
  table breaks.

## verify.sh conventions

Helpers already exist — reuse them, do not reinvent:

`expect` `pass` `fail` `show` `has` · `pod_yaml` `gpu_pods` `net_pod` · `wait_ready` `wait_event`
`uid_of` · `can_i` `check_can` `dry_run_as_tenant` · `curl_from` `ns_label` · `converge`
`check_fleet` `run_case` · `onboard` (in `lib.sh`)

To add a case: write `case_<name>()` and add `<name>` to `CASES=`. `run_case` calls `converge`
before and after every case, so a case does not call it itself. Then:

- Print `expect "<predicted artifact>"` **before** acting. The panel tests predict-before-execute.
- Clean up what you create. A case that onboards a fixture deletes its namespace at the end.
- `pod_yaml` sets only a GPU count. To give a test pod CPU or memory requests, insert a
  `resources:` line after its `image:` line with `awk`, the way `case_escalation` adds
  `securityContext`. **This works only for a pod built with `gpus=0`.** With GPUs, `pod_yaml`
  already emits a `resources:` line, and a second one is a duplicate key: add the requests to that
  line instead.
- **A server dry run is checked against quota but holds nothing.** `kubectl create
  --dry-run=server` proves a refusal. Only pods you actually create count toward usage, and only
  those need `converge` to wait for them.
- **`converge` only knows what it is told.** It deletes the `dc-pinned` namespace by name and waits
  only for **GPU** quota usage to reach zero. A new fixture namespace, or a new quota resource
  your case uses, must be added to `converge`. Prefer a loop over `fixtures/*.yaml` to another name.
- Assert the **event**, not the status. `Preempted` is an event; `Evicted` status is also produced
  by OOMKill, node loss and manual deletion. Tie events to the pod UID with `wait_event`, because
  events outlive their pods. With more than one preemptor in a case, also match the preemptor's
  UID in the message, `Preempted by pod <uid>`.
- Assert the **reason**, not the phase. Bare `Pending` is also an image-pull failure.
- **A negative check needs a positive marker.** "Nothing was preempted" also passes when nothing
  could have been. Assert the message that says *why* (the scheduler's or the API server's own
  wording), and pair every denial with an accepted request from the same identity. An absence
  check on a pod ("it was not preempted") also needs that pod `Running` at the time, or it passes
  for a pod that never started.

## Traps that have already bitten

- **`kubectl auth can-i` exits 1 when the answer is "no".** Under `set -o pipefail`, piping it
  turns a correct denial into a script failure and reports a security hole that does not exist.
  Use `can_i` / `check_can`, which capture stdout.
- **`command -v helm` inside a function named `helm` finds the function.** Use `type -P`.
- **The pinned-pod failure message contains BOTH reasons** — `1 Insufficient nvidia.com/gpu,
  2 node(s) didn't match Pod's node affinity/selector`. The scheduler reports one per node.
  Assert that node affinity *appears*; do not assert Insufficient is absent.
- **A quota that counts a resource with no default request refuses every pod.** Adding CPU or
  memory to the entitlement needs a LimitRange with defaults in the same change.
- **A `LimitRange` with `type: Pod` and a GPU max refuses every pod without a GPU limit.** Use the
  admission policy instead.
- **A Container `LimitRange` with `max` and no `default` makes `max` every container's default
  limit.** Set `defaultRequest` only, unless you mean it.
- **PriorityClass `value` and `preemptionPolicy` are immutable.** `kubectl apply` fails with
  `field is immutable`. Delete the PriorityClass and re-apply; `make create` will not fix it.
  `description` is mutable, so editing it applies normally.
- **`kubectl apply` never deletes.** Removing a template from the chart leaves the object in the
  cluster. Delete it by hand.
- **Counting by subtraction hides placement bugs.** Count each pool by node name.
- **A stray `CLAUDE.md` in `chart/templates/` breaks every render.** The claude-mem plugin writes
  `CLAUDE.md` files into directories it sees, and Helm renders every file in `templates/`, so
  `make create` fails with `YAML parse error on tenant/templates/CLAUDE.md`. A local, git-excluded
  `slice/chart/.helmignore` lists `CLAUDE.md` to prevent it. If you see that error, the
  `.helmignore` is missing: delete the stray file and restore it.
- **YAML 1.1 booleans.** A pod named `y`, `n`, `yes`, `no`, `on` or `off` becomes `app: true` in
  `pod_yaml`'s labels and fails to parse. Use real words.

## Out of scope — do not introduce

Cilium (k3s enforces standard NetworkPolicy; installing it reopens a closed decision) · Terraform
(no credentialed providers; manifests plus scripts is the chosen IaC) · a custom controller (right
at 50 tenants, not at 3) · a device plugin or time-slicing (no GPU exists here) · anything needing
a cloud account.

Production-shaped answers belong in `docs/production-design.md`, as prose.
