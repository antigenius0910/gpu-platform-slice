# Production design: multi-tenant GPU platform

**Date:** 2026-09-26
**Status:** Design. Nothing in this document is deployed by this repo.

## How to read this

This document is design, not code. It describes the production platform, on AWS EKS and bare-metal datacenter servers, that the runnable slice represents. The slice lives in `slice/`. `make create && make verify` builds a k3d cluster with fake GPUs, onboards three teams from `slice/tenants/*.yaml`, and proves each boundary on a live cluster. Nothing here asks a reviewer to run Terraform, create an EKS cluster, or hold cloud credentials.

Each slice component stands in for one production component:

| Slice (`slice/`) | Production counterpart |
|---|---|
| k3d agents labelled `platform.example.com/compute-pool=datacenter` and `=cloud` | Karpenter NodePools on EKS (cloud) and static bare-metal node pools (datacenter), carrying the same label |
| Fake `nvidia.com/gpu`, set once by a node-status PATCH in `create.sh` | NVIDIA device plugin DaemonSet, or the NVIDIA GPU Operator, which advertises real GPUs on every kubelet start |
| Tenant Helm chart (`chart/`) rendered with `helm template` and applied with `kubectl apply` | The same chart, versioned and released through the pipeline in [Delivery pipelines](#delivery-pipelines) |
| `ValidatingAdmissionPolicy` `tenant-entitlement` (`platform/admission-policy.yaml`) | The same policy; optionally Kyverno or `MutatingAdmissionPolicy` to inject the class and pool instead of rejecting |
| Standard `NetworkPolicy`, enforced by k3s's built-in policy controller | Cilium, with `CiliumNetworkPolicy` where L7 or FQDN rules are needed |
| `.github/CODEOWNERS` | CODEOWNERS plus branch protection that requires code-owner review |
| `verify.sh` cases | Chainsaw conformance tests that the pipeline runs against a staging cluster |

---

## Requirements and where the slice proves them

### Req 1: fleet as code

One command creates the fleet and one destroys it. At least one schedulable GPU pool, with a cloud pool and a datacenter pool kept apart.

- **Slice:** `make create` and `make destroy` in `slice/`. Two GPU pools of 4 fake GPUs each (8 total).
- **Production:** cluster lifecycle is Terraform, run by the platform pipeline. A pull request produces a `terraform plan`, a platform owner approves it, and the pipeline applies it. Create and destroy are the same reviewed path. No one runs `terraform apply` from a laptop against a shared account.

### Req 2: repeatable tenant onboarding

A small declarative spec per team produces the namespace, RBAC, a ResourceQuota with a GPU cap, a priority tier, and a NetworkPolicy. Teams differ in cap and tier. A new team follows the same code path. The platform team approves every entitlement change, and tenants cannot raise their own entitlement.

- **Slice:** three specs in `slice/tenants/`, one chart, one `onboard()` function in `slice/lib.sh`. `verify.sh` case `overflow` onboards a fourth spec (`fixtures/dc-pinned.yaml`) through the same function. Case `escalation` shows what a tenant identity can and cannot do.

### Req 3: contention and enforced boundaries

Over-cap requests are refused at admission. Priority decides who runs when GPUs are scarce. Tenant A cannot reach tenant B over the network and cannot read tenant B's resources. Impersonation checks show both allowed and denied actions.

- **Slice:** `verify.sh` cases `quota`, `capacity`, `preemption`, `network` and `escalation`. The network case uses a live target (nginx behind a Service in `release-evals`) and a long-lived probe pod in `research`, with a positive control from inside `release-evals` before and after the blocked attempt.
- **Oversubscription:** in production the mechanism is NVIDIA time-slicing, which needs a real GPU and driver. The slice does not use time-slicing. It creates contention by advertising 8 fake GPUs against caps that sum to 14.

**Starvation is expected.** A ResourceQuota cap is a ceiling on what a team may hold at once, not reserved capacity. A team inside its cap can wait indefinitely if other teams hold the physical GPUs. Its pod is admitted (quota passes) and sits `Pending` with event reason `FailedScheduling` and message `Insufficient nvidia.com/gpu`. The platform promises only that the cap is enforced at admission. Two outcomes must stay distinguishable, and the slice tests them separately:

| Outcome | What the tenant sees | Slice case |
|---|---|---|
| Over the cap | Admission error naming `exceeded quota` and `nvidia.com/gpu`. The pod object never exists. | `quota` |
| Inside the cap, no free GPU | Pod admitted, `Pending`, `Insufficient nvidia.com/gpu` | `capacity` |

A team that sits in the second state for long is a capacity-planning conversation with the platform team, not a quota change.

### Req 4: hybrid compute

Workloads run on both AWS EKS and on-premises bare-metal GPU servers. A tenant spec declares `computePool: any | datacenter | cloud`.

- **Slice:** one cluster, two pools. `any` is a preferred node affinity for datacenter that spills to cloud when datacenter is full. `datacenter` or `cloud` is a required node selector that never spills. Case `overflow` shows both.
- **Production:** see [Hybrid compute](#hybrid-compute-cloud-and-datacenter). With two clusters, `any` needs a cross-cluster placement layer; Cilium ClusterMesh alone does not provide it.

---

## Tenant spec and the entitlement chart

### The spec

A tenant spec is the whole interface between a team and the platform. It is abstract on purpose: it names no Kubernetes object. The fields are the same in the slice and in production:

```yaml
# tenants/research.yaml
name: research
gpuCap: 4
tier: low
computePool: any
networkIsolation: namespace
```

| Field | Values | Meaning |
|---|---|---|
| `name` | DNS label | Team name. Becomes the namespace name. |
| `gpuCap` | integer, 0 to 64 | Ceiling on concurrently requested `nvidia.com/gpu`. A ceiling, not a reservation. |
| `tier` | `low` \| `high` | Priority under contention. |
| `computePool` | `any` \| `datacenter` \| `cloud` | `any` prefers datacenter and spills to cloud. The other two are required and never spill. |
| `networkIsolation` | `namespace` | Ingress only from the same namespace. The only mode built. New modes are how exceptions become capabilities. |

`values.schema.json` requires every field and forbids extra keys, so a spec cannot inherit a default it never stated and cannot smuggle in an override. The chart's `values.yaml` is empty for the same reason.

### Tier is abstract

A spec says `tier: low` or `tier: high`. It never names a PriorityClass. The chart maps the tier to a class in template code (`chart/templates/_helpers.tpl`):

| `tier` | PriorityClass | Value | Behaviour |
|---|---|---|---|
| `low` | `tenant-low` | 100 | Queues under contention. Preempted by `tenant-high`. |
| `high` | `tenant-high` | 1000 | `PreemptLowerPriority`. Preempts `tenant-low` when GPUs are short. |

Because the map lives in the template and not in values, a spec cannot override it. Renaming a class or adding a tier is a chart change reviewed by the platform team, and no tenant spec changes.

### What the chart renders

| Object | Purpose |
|---|---|
| `Namespace` | Labels `platform.example.com/tenant`, `/priority-class`, `/compute-pool` record the rendered entitlement. `pod-security.kubernetes.io/enforce: baseline` blocks privileged pods, hostPath and host namespaces. |
| `ServiceAccount` `<name>-sa` | The tenant's workload identity. |
| `Role` + `RoleBinding` `tenant-developer` | Pods, logs, Services, ConfigMaps, Secrets, Deployments and Jobs in the tenant's own namespace. Read-only on its ResourceQuota and Events, so a refused or queued request explains itself. Nothing on the namespace, quota, NetworkPolicy, RBAC or any cluster-scoped object. |
| `ResourceQuota` `gpu-cap` | `requests.nvidia.com/gpu: <gpuCap>` |
| `NetworkPolicy` `tenant-isolation` | Selects every pod (ingress default-deny) and admits ingress from pods in the same namespace only. |

Production adds a `tenant-admin` Role bound to the team's identity-provider group, and CPU and memory ceilings in the same quota. Both need new spec fields, which is a schema change and a chart release, not a per-team edit.

### Why an admission policy as well as RBAC

RBAC stops a tenant from creating a PriorityClass. It does not stop a tenant pod from naming an existing one: a `research` pod could set `priorityClassName: tenant-high`. The cluster-wide `tenant-entitlement` policy closes that gap. It matches pod creation in any namespace labelled `platform.example.com/tenant` and checks two things against the namespace labels, which tenants cannot edit:

1. The pod's `priorityClassName` equals the namespace's `priority-class` label.
2. If the namespace's pool is not `any`, the pod's `nodeSelector` pins it to that pool.

It is one CEL policy for every tenant: no webhook to run, no per-tenant code. The denial message tells the tenant which file to change: `Tier changes are a PR to slice/tenants/<team>.yaml`.

In production the same policy applies. A friendlier variant injects the class and pool instead of rejecting a pod that omits them, using Kyverno, or `MutatingAdmissionPolicy` once it is generally available on the Kubernetes version the fleet runs. The validating policy stays in place behind it, so a mutation bug cannot grant a tier.

Admission runs in this order for a tenant pod: RBAC, Pod Security, `tenant-entitlement`, then ResourceQuota.

### Worked contention numbers

**Slice (what `verify.sh` checks):**

| Tenant | `gpuCap` | `tier` | `computePool` |
|---|---|---|---|
| `research` | 4 | `low` | `any` |
| `release-evals` | 6 | `high` | `any` |
| `inference-eval` | 4 | `high` | `any` |
| **Sum of caps** | **14** | | |

Fleet: 4 fake GPUs on the datacenter node plus 4 on the cloud node, 8 in total. Caps sum to 14 against 8 GPUs, so every team can be inside its cap while some pods wait. `verify.sh` checks this arithmetic before any case runs and stops if a node lost its GPUs.

**Production example (illustrative, not a sizing decision):** one `g4dn.12xlarge` has 4 physical T4 GPUs. With time-slicing at 2 replicas per GPU, the device plugin advertises 4 x 2 = 8 schedulable `nvidia.com/gpu`. With the same three caps (4 + 6 + 4 = 14), contention is built in: 14 > 8. If schedulable GPUs reached 14 or more (for example 4 replicas per GPU, giving 16), every team could hold its full cap at once, and the inside-the-cap `Pending` outcome could not happen. Production caps will differ from the slice's; the rule that matters is to know, per pool, whether the caps sum past capacity and to say so in the capacity plan.

Time-slicing notes for production:

- Keep the device plugin's `renameByDefault: false` so shared GPUs are still advertised as `nvidia.com/gpu` and the quota key `requests.nvidia.com/gpu` keeps working. If shared GPUs are renamed to `nvidia.com/gpu.shared`, the chart must cap that name too.
- Time-slicing shares compute by turns and gives no memory isolation. One replica is a scheduling unit, not a fixed fraction of a GPU. Teams that need isolation go to a pool with MIG or whole GPUs, and that pool is a separate `computePool` value.

---

## How this would split in production

The brief requires one private repository, so the slice is one repo. In production the same content would split across four repositories, all owned by the platform team:

```
github-org/
├── terraform-modules   # Reusable Terraform modules
├── platform-iac        # Cluster instances, tenant specs, conformance tests
├── helm-charts         # Tenant entitlement chart, platform policy chart, workload chart
└── cicd-templates      # Reusable GitHub Actions workflows for tenant app repos
```

Where each slice path lands:

| Slice path | Production home |
|---|---|
| `slice/tenants/*.yaml` | `platform-iac/tenants/*.yaml` |
| `slice/chart/` | `helm-charts/charts/tenant/` |
| `slice/platform/` | `helm-charts/charts/platform-policy/`, installed on every cluster by the cluster modules |
| `slice/verify.sh` | `platform-iac/conformance/` (Chainsaw cases) |
| `pod_yaml` in `slice/verify.sh` | `helm-charts/charts/tenant-workload/` |
| `slice/create.sh`, `slice/destroy.sh` | `platform-iac/clusters/*` plus the pipeline that plans and applies them |
| `.github/CODEOWNERS` | `platform-iac/CODEOWNERS` and `helm-charts/CODEOWNERS`, with branch protection |

### Components

| Component | Production location | Notes |
|---|---|---|
| EKS cluster | `terraform-modules/eks-cluster/` | Pinned supported EKS version, private endpoint, KMS secret encryption |
| Karpenter | `terraform-modules/eks-cluster/helm_release.tf` | Current release. `EC2NodeClass` only: Karpenter provisions EC2 and nothing else. |
| Cilium with ClusterMesh | `terraform-modules/eks-cluster/helm_release.tf` | Current release, ClusterMesh API server enabled, MCS API enabled |
| GPU NodePools | `platform-iac/clusters/gpu-cloud/values/karpenter_nodes.yaml` | `gpu-reserved` (backed by an EC2 On-Demand Capacity Reservation bought at cluster level, not per tenant), `gpu-on-demand`, `gpu-spot` (g5, g4dn) |
| ALB, Contour, ACM, Route53 | `terraform-modules/eks-cluster-ingress/` | Separate from the cluster module so each has its own lifecycle |
| NVIDIA device plugin | EKS: `helm_release.tf`. Bare metal: GPU Operator. | Advertises `nvidia.com/gpu`; carries the time-slicing config |
| KEDA | `terraform-modules/eks-cluster/helm_release.tf` | Current release |
| Priority classes and entitlement policy | `helm-charts/charts/platform-policy/` | `tenant-low`, `tenant-high`, `tenant-entitlement`. Same chart on both clusters. |
| Tenant entitlement chart | `helm-charts/charts/tenant/` | Namespace, ServiceAccount, RBAC, ResourceQuota, NetworkPolicy from one spec |
| Tenant spec files | `platform-iac/tenants/` | One file per team. The source of truth for entitlements. |
| Tenant cloud identity | `terraform-modules/tenant-identity/` | IAM role for the tenant ServiceAccount (IRSA or EKS Pod Identity), S3 access for checkpoints. Reads the same spec file. |
| Workload chart | `helm-charts/charts/tenant-workload/` | The interface tenants deploy through. Reads the namespace's pool label to set placement. |
| CI/CD templates | `cicd-templates/` | Reusable workflows: build, security scan, deploy, rollback |
| Bare-metal cluster | `terraform-modules/bare-metal-k8s-cluster/` | RKE2 or Talos bootstrap on a static node list |

The main change from a Terraform-only design: tenant namespaces, RBAC, quota and network policy come from the Helm chart, not a `tenant-workload` Terraform module. One chart renders identical objects on EKS and on bare metal, `helm template` can check a spec with no cluster at all, and the slice exercises the exact templates production would ship. Terraform keeps what only Terraform can do for a tenant: the AWS IAM role.

### Repo 1: `terraform-modules`

**Role:** module library. Each module is versioned on its own git tag.

```
terraform-modules/
├── eks-cluster/
│   ├── eks.tf                  # EKS cluster (pinned supported version, private endpoint, KMS)
│   ├── helm_release.tf         # Addons: Cilium, Karpenter, KEDA, NVIDIA device plugin,
│   │                           # observability, and helm-charts/platform-policy
│   ├── karpenter.tf            # Karpenter IAM, interruption queue, controller scaffolding
│   └── variables.tf            # VPC, Cilium cluster ID and mesh peers, feature flags
│
├── eks-cluster-ingress/
│   ├── lb.tf                   # ALB with HTTP, HTTPS and gRPC listeners
│   ├── acm.tf                  # ACM certificate with DNS validation
│   ├── route53.tf              # Private hosted zone, A records, cross-account VPC association
│   ├── security_group.tf       # ALB security group and node security group rules
│   ├── wafv2.tf                # Optional WAF association
│   └── variables.tf
│   # Inputs from eks-cluster: cluster_name, node_security_group_id, s3_bucket_logs_id.
│   # Separate so one cluster can carry several ingress stacks (private,
│   # partner-facing, cross-region) without touching the cluster module.
│
├── tenant-identity/
│   ├── iam.tf                  # IAM role trusted by <team>/<team>-sa (IRSA or Pod Identity)
│   ├── s3.tf                   # Checkpoint bucket prefix and policy
│   └── variables.tf            # Reads name from tenants/<team>.yaml via yamldecode()
│
└── bare-metal-k8s-cluster/
    ├── main.tf                 # Bootstrap Kubernetes on bare metal (RKE2 or Talos)
    ├── cilium.tf               # Cilium, pinned to the same version as the EKS cluster
    ├── clustermesh.tf          # ClusterMesh peer pointing at the EKS cluster
    ├── gpu_operator.tf         # NVIDIA GPU Operator: driver, device plugin, time-slicing
    ├── platform_policy.tf      # helm-charts/platform-policy, same release as EKS
    └── variables.tf            # Node IP list, cluster ID, mesh peers, GPU count
```

**Versioning:** each module has its own tag, for example `eks-cluster/v2.x.x`, `eks-cluster-ingress/v1.x.x`, `tenant-identity/v1.x.x`, `bare-metal-k8s-cluster/v1.x.x`.

### Repo 2: `platform-iac`

**Role:** instantiates the modules, holds all Terraform state configuration, and holds the tenant specs.

```
platform-iac/
├── clusters/
│   ├── gpu-cloud/                     # AWS EKS cluster
│   │   ├── eks_cluster.tf             # calls terraform-modules//eks-cluster
│   │   ├── eks_cluster_ingress.tf     # calls terraform-modules//eks-cluster-ingress
│   │   └── values/
│   │       ├── karpenter_nodes.yaml   # gpu-reserved, gpu-on-demand, gpu-spot NodePools.
│   │       │                          # Every node labelled platform.example.com/compute-pool: cloud
│   │       └── nvidia_device_plugin.yaml
│   │           # Time-slicing config. The numbers are stated here, not left implicit:
│   │           #   physical GPUs per node, replicas per GPU, resulting nvidia.com/gpu,
│   │           #   and the sum of caps of tenants that can land on this pool.
│   │           #   Example: g4dn.12xlarge, 4 GPUs x 2 replicas = 8; caps 4 + 6 + 4 = 14 > 8.
│   │
│   └── gpu-datacenter/                # Bare-metal cluster
│       ├── main.tf                    # calls terraform-modules//bare-metal-k8s-cluster
│       ├── nodes.tf                   # Static node list. Every node labelled
│       │                              # platform.example.com/compute-pool: datacenter
│       └── values/
│           ├── cilium_clustermesh.yaml  # Peer config pointing at gpu-cloud
│           └── gpu_operator.yaml        # Bare-metal time-slicing config
│
├── tenants/                           # One file per team. Same schema as slice/tenants/.
│   ├── research.yaml                  # gpuCap: 4, tier: low,  computePool: any
│   ├── release-evals.yaml             # gpuCap: 6, tier: high, computePool: any
│   └── inference-eval.yaml            # gpuCap: 4, tier: high, computePool: any
│
├── identity/
│   └── main.tf                        # for_each over tenants/*.yaml -> tenant-identity module
│
├── conformance/                       # Chainsaw cases. Same cases as slice/verify.sh.
│   ├── quota/
│   ├── capacity/
│   ├── preemption/
│   ├── network/
│   ├── overflow/
│   └── escalation/
│
├── .github/workflows/
│   ├── cluster.yml                    # terraform plan on PR, apply on merge after approval
│   ├── tenants.yml                    # render and schema-check on PR, release on merge
│   └── conformance.yml                # Chainsaw against staging after every platform change
│
└── CODEOWNERS
```

`CODEOWNERS` works on paths, not on variables inside a file, so the layout puts every entitlement in a path the platform team owns:

```
/tenants/     @example-org/platform-leads
/identity/    @example-org/platform-leads
/clusters/    @example-org/platform-leads
/.github/     @example-org/platform-leads
```

CODEOWNERS only names reviewers. The enforcement is branch protection on `main` with "Require review from Code Owners" turned on, which the slice notes in its own `CODEOWNERS` file. A tenant who opens a pull request raising their `gpuCap` cannot merge it without a platform lead's approval. Tenants own their app repos and have no write access to `platform-iac`.

### Repo 3: `helm-charts`

**Role:** every chart the platform ships.

```
helm-charts/
├── charts/
│   ├── tenant/               # Entitlement chart. Same templates and schema as slice/chart/.
│   ├── platform-policy/      # PriorityClasses and tenant-entitlement. Same objects as slice/platform/.
│   └── tenant-workload/      # How tenants deploy: Deployment or Job, Service, HTTPRoute,
│                             # ServiceMonitor. Reads the namespace's pool and priority labels.
└── ct.yaml                   # chart-testing config
```

**Publishing:** a git tag such as `tenant/v1.x.x` makes GitHub Actions publish the chart to GHCR as an OCI artifact.

**Tenant interaction:** each tenant app repo has `helm/values/{cluster}.yaml` for the `tenant-workload` chart (image, resource requests, environment, routes). Tenants never edit a chart. They never install the `tenant` or `platform-policy` charts at all; only the platform pipeline does.

### Repo 4: `cicd-templates`

**Role:** reusable GitHub Actions workflows that tenant app repos call.

```
cicd-templates/
├── .github/workflows/
│   ├── build.yml          # Docker build and push to the registry
│   ├── deploy.yml         # helm upgrade --install of tenant-workload from GHCR
│   ├── lambda-deploy.yml  # Lambda: zip, ECR or S3 modes
│   └── stages.yml         # Standard stages: build, security, deploy-test, deploy-prod, rollback
└── scripts/
    └── deploy.sh          # The helm invocation
```

**How it connects:**

- A tenant app repo's `.github/workflows/deploy.yml` calls `org/cicd-templates/.github/workflows/deploy.yml@vX.Y.Z`.
- The deploy job authenticates with GitHub's OIDC token, not a stored kubeconfig. On EKS the token assumes an IAM role mapped by an EKS access entry to the tenant's namespace-scoped RBAC. On bare metal the API server trusts GitHub's OIDC issuer directly and maps the repository claim to the same RBAC. No long-lived cluster credential sits in a GitHub secret.
- The job pulls `oci://ghcr.io/org/helm-charts/tenant-workload` at a pinned version and merges the tenant's `helm/values/{cluster}.yaml`.
- The deploy identity has exactly the tenant's `tenant-developer` rights, so a deploy cannot do anything the tenant could not do by hand. Quota, the entitlement policy and Pod Security apply to it the same way.

---

## Delivery pipelines

This section replaces a laptop run-book. Every step below is a reviewed pull request followed by a pipeline run.

### Cluster lifecycle

```
[Create or change a cluster]
  PR to platform-iac/clusters/gpu-cloud/
    -> cluster.yml: terraform fmt, validate, tflint, terraform plan (posted on the PR)
    -> platform lead approves (CODEOWNERS + branch protection)
    -> merge -> cluster.yml: terraform apply of the reviewed plan
    -> EKS up, Karpenter ready, Cilium installed, device plugin advertising GPUs
    -> platform-policy chart installed: tenant-low, tenant-high, tenant-entitlement
    -> conformance.yml runs against the cluster

[Destroy a cluster]
  PR that removes the instance -> plan shows the destroy -> approval -> apply
```

`clusters/` applies before tenants are onboarded to a cluster: the tenant chart depends on the priority classes and the entitlement policy existing. The slice's `make create` and `make destroy` stand in for this path; they are not how production clusters are built.

### Tenant onboarding and entitlement changes

```
[Onboard a team, or change a cap, tier or pool]
  PR adding or editing platform-iac/tenants/<team>.yaml
    -> tenants.yml: helm template helm-charts/tenant at the pinned version with -f <spec>
       (values.schema.json rejects a malformed spec before any cluster sees it)
    -> tenants.yml: kubeconform on the rendered objects; diff against the live cluster
    -> platform lead approves (CODEOWNERS on /tenants/)
    -> merge -> tenants.yml: helm upgrade --install <team> for each cluster the pool allows
       -> Namespace with tenant, priority-class and compute-pool labels, Pod Security baseline
       -> ServiceAccount, Role and RoleBinding tenant-developer
       -> ResourceQuota gpu-cap (research 4, release-evals 6, inference-eval 4)
       -> NetworkPolicy tenant-isolation
    -> identity/: terraform plan and apply for the team's IAM role
```

Onboarding a new team is one new file. The slice shows this: `inference-eval` needed its spec and nothing else, and `verify.sh` onboards the `dc-pinned` fixture through the same `onboard()` path. Offboarding is removing the file, which uninstalls the release and deletes the namespace.

The slice renders with `helm template` and applies with `kubectl apply`, so it holds no Helm release state. Production uses `helm upgrade --install` so each team has a release history and a rollback, and so objects the chart stops rendering are deleted. A GitOps controller (Argo CD or Flux) watching `tenants/` is an equal alternative to the push pipeline; the chart and the spec do not change either way.

### Conformance tests

The six `verify.sh` cases become Chainsaw tests in `platform-iac/conformance/`. `conformance.yml` runs them against a staging cluster after every change to a cluster, the tenant chart or the policy chart, and on a schedule. The pipeline authenticates through GitHub OIDC to a staging-only role. There is no manual demo workflow and no kubeconfig secret.

Each case directory is self-contained: it applies its own setup, runs its own assertions and, with Chainsaw's default of cleaning up what it created, removes everything when it ends. Any case can run alone and in any order, which is the same property `verify.sh` gets from its `converge` step. The JUnit report publishes as a GitHub Check, and that check is the pass or fail signal. A Helm exit code is not a substitute: a Deployment applies successfully even when every pod it creates is refused by quota, because the refusal happens on the child pod.

| Case | Setup | Assertion | Pitfall the assertion avoids |
|---|---|---|---|
| `quota` | A `research` pod asking for 5 GPUs (cap 4) | The apply errors with both `exceeded quota` and `nvidia.com/gpu`; then the pod is `NotFound` | Matching only `exceeded quota` passes falsely when a CPU or memory quota fires first |
| `capacity` | High-tier pods hold every GPU, each team inside its cap; `research` (0 of 4 used) asks for 1 | Pod admitted; `FailedScheduling` event containing `Insufficient nvidia.com/gpu`; no node assigned | `Pending` alone also covers a bad image pull |
| `preemption` | `research` fills GPUs at `tenant-low` and waits for Running; `release-evals` fills the rest; one more `release-evals` pod | The high-tier pod reaches Running, and a `Preempted` event exists on one of this run's `research` pods (matched by UID) | Asserting status `Evicted`: OOM kills, node loss and manual deletion look the same. Matching events by name picks up a previous run's event. |
| `network` | nginx target and Service in `release-evals`; long-lived curl probe in `research`; a second probe inside `release-evals` | Positive control returns 200; the cross-tenant probe fails; the positive control still returns 200 afterwards | A young cluster's DNS or endpoint failure looks exactly like a policy block, so no isolation result counts without the control |
| `overflow` | `release-evals` (pool `any`) submits 6 x 1 GPU; a datacenter-pinned tenant asks for 1 while datacenter is full | 4 land on datacenter and 2 spill to cloud; the pinned pod is `Pending` with a node-affinity reason, not a capacity reason | Counting cloud as "total minus datacenter" hides a pod on an unexpected node |
| `escalation` | Impersonate `system:serviceaccount:research:research-sa` | Allowed: list pods in `research`, create a pod at `tenant-low`. Denied: list pods in `release-evals`, patch own quota, patch own namespace, create a PriorityClass, a pod naming `tenant-high` (by `tenant-entitlement`), a privileged pod (by Pod Security) | A denial proves nothing unless the same identity can create an ordinary pod, so the allowed pod is the positive control |

The network assertion differs by enforcer. In the slice, k3s's built-in policy controller rejects the connection and curl exits 7 (connection refused) within the 5-second limit. Cilium drops denied packets by default, so in production the probe times out (curl exit 28) and the case asserts the timeout, with the Hubble flow verdict `DROPPED` as corroborating evidence.

The Chainsaw specs are described by shape here (apply and expect an error, assert on `Event` objects, script steps with checks). The exact assertion syntax is checked against Chainsaw's assertion library when the cases are written; the commitment is the shape: declarative, one directory per case, self-cleaning.

### Tenant application deploys

```
[Tenant ships a new model server]
  tenant app repo -> build.yml -> deploy.yml@vX.Y.Z
    -> GitHub OIDC -> tenant-scoped identity on the target cluster
    -> helm upgrade --install tenant-workload (pinned version) -f helm/values/<cluster>.yaml
    -> admission: RBAC, Pod Security, tenant-entitlement, ResourceQuota
    -> scheduler places pods by tier and pool
```

---

## Hybrid compute: cloud and datacenter

| Aspect | Cloud (AWS EKS) | Datacenter (bare metal) |
|---|---|---|
| Cluster module | `terraform-modules/eks-cluster` | `terraform-modules/bare-metal-k8s-cluster` |
| Node provisioning | Karpenter (`EC2NodeClass`) | Static node list in `nodes.tf`. Karpenter is EC2-only. |
| Automated node replacement | Karpenter | Cluster API with Metal3 (CAPM3). Deferred; see [Replacement](#replacement). |
| Node label | `platform.example.com/compute-pool: cloud` | `platform.example.com/compute-pool: datacenter` |
| GPU stack | EKS accelerated AMI (driver) plus NVIDIA device plugin | NVIDIA GPU Operator (driver, device plugin, time-slicing) |
| Networking | Cilium with ClusterMesh | Cilium with ClusterMesh, peered to EKS |
| Priority and entitlement policy | `platform-policy` chart | Same chart, same version |
| Tenant targeting | `computePool: cloud` or `any` | `computePool: datacenter` or `any` |
| Ingress | ALB through `eks-cluster-ingress` | NodePort or a bare-metal load balancer |
| CI/CD deploy | Same `cicd-templates`, OIDC to an EKS access entry | Same `cicd-templates`, OIDC trusted by the API server |

### What ClusterMesh does and does not do

**ClusterMesh peer registration** runs in both directions: `gpu-cloud` adds `gpu-datacenter` as a mesh peer, and `gpu-datacenter` adds `gpu-cloud`. Both clusters pin the same Cilium version, have unique cluster names and IDs, and use non-overlapping pod CIDRs.

ClusterMesh gives cross-cluster service discovery and load balancing: a pod in one cluster can reach a global Service backed by pods in both, and network policy can name identities in the peer cluster. That is connectivity. It is not placement. The Kubernetes scheduler is per cluster: a pod that is `Pending` in `gpu-datacenter` stays `Pending` there. It never moves to `gpu-cloud`, however many GPUs are free there.

### Placement: what `computePool: any` means across two clusters

In the slice, both pools are nodes in one cluster, so `any` is just a preferred node affinity and one scheduler handles the spill. Production has two clusters, and that affects two things:

1. **Spill.** Moving a waiting workload from datacenter to cloud needs a layer above the per-cluster schedulers. Options are Kueue's MultiKueue (a manager cluster dispatches Jobs to worker clusters that have quota free), Karmada (propagation policies across member clusters) or Liqo (a peer cluster appears as a virtual node, which brings back the slice's one-scheduler model).
2. **The cap.** A ResourceQuota is per cluster. Onboarding a `gpuCap: 4` team to both clusters with a quota of 4 in each lets it hold 8. Either the cap is split per cluster and stated in the spec, or it moves to the placement layer (a Kueue ClusterQueue on the manager cluster), with each cluster's ResourceQuota kept as a backstop.

| Topology | `any` spill | Cap | Cost |
|---|---|---|---|
| Two clusters, no placement layer | None. `any` means "onboarded to both; the tenant picks a cluster at deploy time". | Split per cluster | Simplest; teams do the placement themselves |
| Two clusters plus MultiKueue | Jobs dispatched to whichever cluster has room | Global, in the ClusterQueue | Kueue becomes the GPU entry point; tenants submit Jobs through queues |
| Datacenter cluster plus Liqo (the cloud cluster appears as a virtual node) | The datacenter scheduler spills by node affinity, as in the slice | One ResourceQuota in the datacenter cluster, as in the slice | Another component in the data path; the virtual node shows the cloud cluster's GPUs as one pooled total |
| One control plane over both pools (EKS Hybrid Nodes) | The scheduler spills by node affinity, exactly as in the slice | One ResourceQuota, exactly as in the slice | The datacenter depends on the AWS control plane and on the WAN link to it |

**Decision in this design:** two clusters, with MultiKueue as the placement layer for GPU Jobs. The datacenter keeps its own control plane and keeps running if the WAN link drops, and the cap stays global. Until MultiKueue is in place, `any` tenants get a per-cluster cap split written in the capacity plan, and the spill behaviour shown in the slice's `overflow` case applies within each cluster's pools only.

---

## Approval and governance summary

| Action | Who approves | Mechanism |
|---|---|---|
| Onboard a new team | Platform leads | New file under `platform-iac/tenants/`; CODEOWNERS on `/tenants/` plus branch protection |
| Raise or lower a GPU cap | Platform leads | Edit `gpuCap` in the team's spec; same path rule |
| Change a tier or pool | Platform leads | Edit `tier` or `computePool`; same path rule |
| Change the tier-to-class map or add a tier | Platform leads | PR to `helm-charts/charts/tenant/` (template and schema) and `charts/platform-policy/` |
| Change the entitlement policy | Platform leads | PR to `helm-charts/charts/platform-policy/` |
| Chart version bump | Platform team | PR to `helm-charts/`, then a pin bump in `platform-iac` |
| App deployment inside the cap | Tenant team | Tenant's own app repo; enforced at admission, not by review |
| Add a bare-metal node | Platform leads | PR to `platform-iac/clusters/gpu-datacenter/nodes.tf` |

What stops a tenant raising its own entitlement, layer by layer:

| Attempt | Stopped by |
|---|---|
| Merge a spec change | Branch protection requiring a code-owner review |
| Edit its ResourceQuota, NetworkPolicy, Role or namespace labels | RBAC: `tenant-developer` has no write verbs on these |
| Create a PriorityClass | RBAC: no cluster-scoped rights |
| Name an existing higher PriorityClass on a pod | `tenant-entitlement` admission policy |
| Leave its pinned pool | `tenant-entitlement` admission policy |
| Run a privileged pod or mount the host | Pod Security `baseline` on the namespace |

---

## Release strategy: each repo releases on its own tags

Every repo is tag-releasable on its own, so a change can be tested from a branch before it reaches `main`.

| Repo | Versioning | Publish | Automation |
|---|---|---|---|
| `terraform-modules` | Per-module git tag `<module>/vX.Y.Z` | Git tag ref, no registry | release-please opens the release PR and creates tags |
| `cicd-templates` | Repo-level git tag `vX.Y.Z` | Consumed by git ref | release-please; consumers pin the ref |
| `helm-charts` | `Chart.yaml` version, increment enforced in CI | GHCR (OCI), stable and alpha | CI publishes alpha on PR, stable on merge |
| `platform-iac` | Not released; `main` is the desired state | Applied by its pipelines | Pins every module, chart and template version it uses |

### Where artifacts live

GitHub has no native Terraform module registry. Each artifact type has a natural home:

| Artifact | Registry | Why |
|---|---|---|
| Terraform modules | Git tag ref, no registry | `source = "github.com/org/terraform-modules//eks-cluster?ref=eks-cluster/vX.Y.Z"`, the pattern public module collections use |
| Helm charts | GHCR (OCI), `ghcr.io/org/helm-charts` | GitHub-native; current Helm supports OCI, so no `index.yaml` to maintain |
| CI/CD templates | Reusable workflows at a tag, no registry | `uses: org/cicd-templates/.github/workflows/deploy.yml@vX.Y.Z` |

### `terraform-modules` release CI

```
.github/
└── workflows/
    ├── ci.yml        # On every PR: terraform validate, fmt check, tflint per changed module
    └── release.yml   # On push to main: release-please writes the CHANGELOG and bumps
                      # the per-module tag. No publish step: callers reference the tag.
```

**Caller pinning, in `platform-iac`:**

```hcl
module "eks_cluster" {
  source = "github.com/org/terraform-modules//eks-cluster?ref=eks-cluster/vX.Y.Z"
}
```

**Testing a branch before it is tagged**, in a staging cluster instance only:

```hcl
module "eks_cluster" {
  source = "github.com/org/terraform-modules//eks-cluster?ref=feature/add-node-repair"
}
```

A branch ref works directly, so there is no alpha publishing step.

### `cicd-templates` release CI

```
.github/
└── workflows/
    ├── ci.yml        # On every PR: yamllint, actionlint, shellcheck on scripts/
    ├── build.yml     # Reusable: Docker build and push
    ├── deploy.yml    # Reusable: helm upgrade --install
    └── release.yml   # On push to main: release-please bumps the tag and creates a GitHub Release
```

**Consumer pinning, in each app repo:**

```yaml
jobs:
  deploy:
    uses: org/cicd-templates/.github/workflows/deploy.yml@vX.Y.Z
```

**Trying a new template on one app before merge:**

```yaml
jobs:
  deploy:
    uses: org/cicd-templates/.github/workflows/deploy.yml@feature/new-deploy-strategy
```

Any tag or branch ref works, with no extra infrastructure.

### `helm-charts` release CI

```
.github/
└── workflows/
    ├── ci.yml        # On every PR: helm lint, ct lint (enforces a version bump), kubeconform.
    │                 # For charts/tenant: render every spec in platform-iac/tenants/ against
    │                 # the new schema, so a schema change cannot strand an existing team.
    ├── alpha.yml     # On every PR: package and push <version>-alpha.<short-sha> to GHCR
    └── release.yml   # On push to main: package and push <version> to GHCR
```

**Consumer pinning, in the `cicd-templates` deploy script:**

```bash
# Stable: set once; every consumer uses it unless it overrides the variable.
TENANT_WORKLOAD_CHART_VERSION="${TENANT_WORKLOAD_CHART_VERSION:-<version>}"

helm upgrade --install myapp \
  oci://ghcr.io/org/helm-charts/tenant-workload \
  --version "${TENANT_WORKLOAD_CHART_VERSION}"
```

**Testing a chart PR before merge:**

```bash
# One app repo sets this in its workflow to try the alpha.
TENANT_WORKLOAD_CHART_VERSION=<version>-alpha.<short-sha>
```

Only that app uses the alpha chart; every other team is unaffected. The `tenant` and `platform-policy` charts are tried the same way, by pinning the alpha in the staging cluster's instance in `platform-iac` and letting `conformance.yml` run.

### Release flow summary

```
[Terraform module change]
  PR in terraform-modules/eks-cluster/
    -> CI: terraform validate, tflint
    -> staging instance pins the branch ref; plan and apply there; conformance passes
    -> merge -> release-please release PR -> merge -> tag eks-cluster/vX.Y.Z
    -> platform-iac bumps source ref to eks-cluster/vX.Y.Z (a reviewed PR)

[Helm chart change]
  PR in helm-charts/ bumping Chart.yaml <old> -> <new>
    -> CI: helm lint, ct lint, kubeconform, render every tenant spec
    -> alpha.yml publishes <new>-alpha.<short-sha>
    -> staging (platform charts) or one test app (tenant-workload) pins the alpha; conformance passes
    -> merge -> release.yml publishes <new>
    -> platform-iac or cicd-templates bumps its pin to <new>

[CI template change]
  PR in cicd-templates/
    -> CI: yamllint, actionlint, shellcheck
    -> one test app uses deploy.yml@feature/new-step
    -> merge -> release-please tag vX.Y.Z -> GitHub Release
    -> app repos adopt deploy.yml@vX.Y.Z
```

---

## GPU node disappearance: detection, replacement, queued work, lost progress

### Detection timeline

With default settings on Kubernetes 1.35 (`node-monitor-grace-period` 50s, which was 40s before 1.32, and a default NoExecute toleration of 300s):

```
t=0       The node stops sending kubelet heartbeats (power loss, kernel panic,
          network partition, spot reclaim without notice).
t≈50s     node-lifecycle-controller marks the Ready condition Unknown and adds
            node.kubernetes.io/unreachable:NoExecute
          The scheduler stops placing pods on the node because of the taint
          and the condition. .status.capacity and .status.allocatable keep
          their last values; nothing zeroes nvidia.com/gpu.
t≈50-350s Pods on the node still show Running in the API but are unreachable.
          The DefaultTolerationSeconds admission plugin gave every pod a
          300s toleration for the unreachable and not-ready taints.
t≈350s    The taint manager evicts those pods. Controller-owned pods (Job,
          Deployment) get replacement pods, which go through admission and
          the scheduler as new pods. Bare pods are not recreated. Evicted
          pods with a grace period stay Terminating, because no kubelet can
          confirm them, and they keep counting against the team's quota
          until the node is marked out-of-service (see Queued work).
```

**Measured on 29 September 2026 on k3d clusters built like the slice** (not a `verify.sh` case), with `node-monitor-grace-period=20s` on the controller manager and both `default-not-ready-toleration-seconds=20` and `default-unreachable-toleration-seconds=20` on the API server, after stopping the datacenter node. [`ARCHITECTURE.md`](ARCHITECTURE.md#reproduce-the-node-loss-measurement) has the commands.

| Event | Observed |
|---|---|
| Ready becomes `Unknown`, `unreachable:NoExecute` taint added | t+14s to t+20s across three runs |
| Deployment's replacement pods Running on the cloud node (0s grace period) | t+38s |
| Same, with only the not-ready toleration shortened | t+315s. Each pod still carried `unreachable NoExecute 300` |
| `.status.capacity` `nvidia.com/gpu` on the stopped node | Still `4` throughout |

A stopped node gets the `unreachable` taint, whose default toleration comes from `default-unreachable-toleration-seconds`, a separate flag from the not-ready one. Both are API server flags: the `DefaultTolerationSeconds` admission plugin writes them into each pod when it is created. The earlier notes for this measurement named only the not-ready flag. The measurement above shows that shortening only that one leaves eviction at five minutes.

**On EKS these flags are not settable**, because the control plane is managed. The production lever is per pod: the `tenant-workload` chart sets explicit tolerations for `node.kubernetes.io/unreachable` and `node.kubernetes.io/not-ready` with a short `tolerationSeconds` (for example 60) on GPU Jobs, where waiting five minutes for a dead node to return costs more than rescheduling. Long-running inference Deployments keep the default.

**Spot interruption:** AWS sends a two-minute interruption notice. Karpenter's native interruption handling (an SQS queue fed by EventBridge) receives it, taints and drains the node, and starts a replacement ahead of the reclaim, which gives running pods the notice window to checkpoint. Do not also run `aws-node-termination-handler`; both would act on the same event. Without either, the first signal is the kubelet going silent.

### What happens to GPU capacity on node loss

Extended resources such as `nvidia.com/gpu` are advertised by the NVIDIA device plugin through the kubelet. When a node disconnects:

1. The node is tainted `node.kubernetes.io/unreachable:NoExecute` and its Ready condition becomes `Unknown`. The scheduler stops placing pods there because of the taint and the condition. **The capacity field is not zeroed.** `.status.capacity` keeps reporting its last value. (Measured 2026-09-28: the field read `4` throughout.)
2. Pods already running on the lost node show `Running` until their toleration expires, then are evicted.
3. Extended-resource capacity lives on the **Node object**. It survives anything that keeps that object: a container restart, a reboot, a kubelet restart. It is lost only when the object is recreated: the node is deleted, replaced, or a new node joins. (Measured 2026-09-28: restart kept the capacity; deleting the Node object lost it; a new node had none.)

That third point is why production advertises GPUs through a device plugin. The device plugin is a DaemonSet, and it re-registers with the kubelet on every kubelet start, so capacity comes back after a replacement as well as after a restart. The slice's one-time PATCH covers only restart, which is why `create.sh` re-applies it on every run and `verify.sh` refuses to start if a pool has lost its GPUs.

### Replacement

**Cloud, with Karpenter:**

```
Node lost -> pods evicted after tolerationSeconds
  -> controller-owned pods get replacement pods, which are Pending
  -> Karpenter sees Pending pods it can place and launches an EC2 instance from the NodePool
  -> kubelet starts, node joins (typically 2-3 minutes)
  -> device plugin starts and advertises nvidia.com/gpu
  -> scheduler binds the Pending pods
```

Karpenter provisions for the Pending pods; it does not need to diagnose the dead node first. Removing the dead node and its instance is Karpenter's node auto-repair (behind a feature gate in the releases this design was checked against; confirm for the pinned version), or an operator action until that is enabled.

The `gpu-reserved` NodePool draws from an EC2 On-Demand Capacity Reservation. The reservation holds GPU capacity in the Availability Zone, so a replacement does not fail for lack of instances, but it still pays the full boot and join time. Plan for 2 to 5 minutes end to end.

**Bare metal, manual today:** there is no automated replacement in this design. A failed server is repaired or re-imaged by hand, and it rejoins as the same Node or as a new one (in which case the device plugin advertises its GPUs again). The next step is Cluster API with Metal3 (CAPM3), which can re-provision a server through its BMC. Karpenter has no bare-metal provider, so CAPM3 is the equivalent, and it is deferred.

### Queued work

| Workload at node loss | What happens |
|---|---|
| `Pending` pod, waiting for a GPU | Unaffected. It stays `Pending` and schedules when capacity appears. |
| Pod owned by a Job | Evicted when the toleration expires. The Job controller creates a new pod (counted against `backoffLimit` by default; a `podFailurePolicy` can ignore disruptions). The new pod runs from the start of its command. |
| Pod owned by a Deployment or ReplicaSet | Evicted; the controller creates a replacement. |
| Bare pod | Evicted and gone. Someone must resubmit it. |
| `Completed` or `Failed` pod | Terminal. Not affected, not rescheduled. |

`restartPolicy` does not move a pod. It restarts containers on the same node. A pod is never rescheduled; only a controller creating a new pod gets work onto another node. This is why the `tenant-workload` chart submits GPU work as Jobs, not bare pods.

**Quota and re-submission:** ResourceQuota is charged at admission and counts every non-terminal pod, `Pending` included. A replacement pod passes admission again. Measured on the slice: evicted pods with a 30s grace period stayed `Terminating` on the dead node and kept counting, so a team at its cap had every replacement refused with `exceeded quota`. Tainting the node `node.kubernetes.io/out-of-service=nodeshutdown:NoExecute` made the pod garbage collector force-delete them within 15s, and the replacements were admitted and running a second later. The platform applies that taint only after it has fenced the node: on a node that is merely partitioned, the old pods may still run, and the taint would start a second copy. In production this belongs in the node-failure runbook, and later in automation that confirms power-off through the BMC or the EC2 API first. Once admitted, it holds its share of the cap while it waits. If another team has taken the recovered GPUs, it waits `Pending` with `Insufficient nvidia.com/gpu`. **A cap is not a queue position or a reservation.**

### Lost progress

GPU training state lives in GPU memory. When the process dies, that state is gone. How much work survives depends on checkpointing:

| Strategy | Recovery point | Owner |
|---|---|---|
| No checkpoint | Start over | None |
| Epoch-level checkpoint to a shared PVC | Last completed epoch | Application team |
| Checkpoint to S3 every N minutes (PyTorch Lightning, DeepSpeed) | Last N-minute interval | Application team |
| Gradient checkpointing | Not fault tolerance. It saves memory only. | None |

**Platform responsibility:** provide the PVC, or the IAM role (from `tenant-identity`) with access to the team's checkpoint prefix in S3. The platform does not write checkpoints and does not resume jobs.

**What the platform does after node loss:**

- Controller-owned pods get replacements, which schedule when capacity returns.
- A replacement pod is not dropped silently. It either fails admission with a quota message or waits `Pending` with a visible reason.
- The reason for `Pending` is on the pod: `kubectl describe pod` shows `FailedScheduling` with `Insufficient nvidia.com/gpu`, and the tenant's Role can read it.

---

## Key design principles

1. **The tenant spec is the interface.** Five abstract fields, no Kubernetes object names. Changing the platform's internals (class names, policy engine, CNI) does not touch a spec.
2. **One chart renders every tenant, on every cluster.** The slice runs the same templates production ships.
3. **A cap is a ceiling, not a reservation.** Caps may sum past capacity on purpose; tier decides who waits.
4. **Entitlements are enforced in layers.** Branch protection on the spec, RBAC on the objects, an admission policy on the pod, Pod Security on the node.
5. **Cluster layer before tenant layer.** Clusters, priority classes and the entitlement policy exist before any tenant chart is installed.
6. **Each ingress stack is independent.** One cluster can carry several (private, external, gRPC).
7. **Versions are pinned at the call site.** Modules by git tag, charts by OCI version, templates by workflow ref.
8. **ClusterMesh is connectivity, not placement.** Adding the bare-metal cluster as a mesh peer is a config change; spilling work between clusters needs a placement layer (MultiKueue in this design).
9. **Karpenter for cloud, static nodes for bare metal.** Karpenter is EC2-only; Cluster API with Metal3 is the bare-metal path, deferred.
10. **CODEOWNERS plus branch protection is the approval mechanism**, not a separate approval service.
11. **Conformance tests are self-contained and CI-native.** Each case sets up, asserts on the artifact that proves the behaviour (an event, an admission error, a curl exit code), and cleans up. The pipeline runs them against staging after every platform change, and the slice's `verify.sh` is the same cases on a laptop.
