#!/usr/bin/env bash
# Proves the platform's boundaries on a live cluster. Usage:
#   ./verify.sh                 all cases, in order
#   ./verify.sh network quota   named cases only, in the order given
#
# Every case prints EXPECT: before it acts, so the prediction is on screen before
# the evidence. Every case starts by converging to an empty state and cleans up
# after itself, so any case can run alone, in any order, on a cluster that
# already has state.
#
# Assertions check the artifact that proves the behaviour, not a proxy for it:
# an event message, not a pod phase; a Preempted event, not status Evicted;
# both halves of a quota error, not either one.
set -uo pipefail # no -e: a failed assertion is recorded, and the next case still runs
source "$(dirname "$0")/lib.sh"

CASES=(quota capacity preemption network overflow escalation)
TENANTS=(research release-evals inference-eval)
FIXTURE="$SLICE_DIR/fixtures/dc-pinned.yaml"
MARK="platform.example.com/verify"      # label on every object this script creates
POOL_LABEL="platform.example.com/compute-pool"
RESEARCH_SA="system:serviceaccount:research:research-sa"
PASS=0
FAIL=0

expect() { printf '    EXPECT: %s\n' "$*"; }
pass()   { printf '    PASS:   %s\n' "$*"; PASS=$((PASS + 1)); }
fail()   { printf '    FAIL:   %s\n' "$*"; FAIL=$((FAIL + 1)); }
show()   { printf '            %s\n' "$*"; }
has()    { grep -qF -- "$2" <<<"$1"; } # has <haystack> <needle>

# --- workload template ----------------------------------------------------------
# Stands in for the tenant workload chart production would ship. It reads the
# entitlement the tenant chart wrote on the namespace, so a pod carries its
# tier's PriorityClass and its pool placement without the author naming either.
#   pool any        -> PREFERRED affinity for datacenter: spills to cloud when full
#   pool datacenter -> REQUIRED nodeSelector: never spills
ns_label() { kubectl get ns "$1" -o jsonpath="{.metadata.labels.platform\.example\.com/$2}"; }

pod_yaml() { # <ns> <name> <gpus> [priorityClassName override]
  local ns="$1" name="$2" gpus="$3" class="${4:-}" pool placement resources=""
  [ -n "$class" ] || class="$(ns_label "$ns" priority-class)"
  pool="$(ns_label "$ns" compute-pool)"
  if [ "$pool" = any ]; then
    placement="  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - { key: $POOL_LABEL, operator: In, values: [datacenter] }"
  else
    placement="  nodeSelector: { $POOL_LABEL: $pool }"
  fi
  [ "$gpus" -gt 0 ] && resources="      resources: { limits: { nvidia.com/gpu: \"$gpus\" } }"
  cat <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $name, namespace: $ns, labels: { $MARK: "true", app: $name } }
spec:
  priorityClassName: $class
  terminationGracePeriodSeconds: 0
$placement
  containers:
    - name: work
      image: registry.k8s.io/pause:3.10
$resources
YAML
}

gpu_pods() { # <ns> <prefix> <count>: submit <count> pods of 1 GPU each
  local i
  for i in $(seq 1 "$3"); do
    pod_yaml "$1" "$2-$i" 1 | kubectl apply -f - >/dev/null || fail "could not submit $1/$2-$i"
  done
}

wait_ready() { # <ns> <timeout-seconds> [selector]: every marked pod Ready
  kubectl -n "$1" wait pod -l "${3:-$MARK=true}" --for=condition=Ready --timeout="${2}s" >/dev/null
}

uid_of() { kubectl -n "$1" get pod "$2" -o jsonpath='{.metadata.uid}'; }

# Events outlive the pods they describe, so a match must be tied to this run's
# pod UID. Otherwise a previous run's Preempted event would pass today's case.
wait_event() { # <ns> <uid> <reason> <timeout>: prints the messages once any appear
  local i msg
  for i in $(seq 1 "$4"); do
    msg="$(kubectl -n "$1" get events \
      --field-selector "involvedObject.uid=$2,reason=$3" -o jsonpath='{.items[*].message}')"
    [ -n "$msg" ] && { printf '%s' "$msg"; return 0; }
    sleep 1
  done
  return 1
}

# --- converge -------------------------------------------------------------------
# Remove everything any case creates and wait until quota usage reads zero. The
# quota controller updates usage asynchronously after a delete, and admission
# checks against that recorded usage, so without the wait a case can be refused
# by the previous case's pods.
converge() {
  local i used
  kubectl delete ns dc-pinned --ignore-not-found --wait=true >/dev/null
  kubectl delete pods,services -A -l "$MARK=true" --force --grace-period=0 >/dev/null 2>&1
  for i in $(seq 1 60); do
    used="$(kubectl get resourcequota -A -o jsonpath='{.items[*].status.used.requests\.nvidia\.com/gpu}')"
    if [ -z "$(kubectl get pods -A -l "$MARK=true" -o name)" ] && [ -z "$(tr -d ' 0' <<<"$used")" ]; then
      return 0
    fi
    sleep 1
  done
  die "could not converge: marked pods or GPU quota usage remain after 60s"
}

# The premise every case rests on. If a node was replaced, its fake GPUs are gone
# and the arithmetic below is false; say so instead of failing mysteriously.
check_fleet() {
  local dc cloud ns
  dc="$(kubectl get nodes -l "$POOL_LABEL=datacenter" -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}')"
  cloud="$(kubectl get nodes -l "$POOL_LABEL=cloud" -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}')"
  [ "$dc" = 4 ] && [ "$cloud" = 4 ] ||
    die "fleet should advertise nvidia.com/gpu 4+4, found datacenter='$dc' cloud='$cloud'. Re-run ./create.sh."
  for ns in "${TENANTS[@]}"; do
    kubectl get ns "$ns" >/dev/null 2>&1 || die "tenant $ns is not onboarded. Run ./create.sh."
  done
  say "fleet: datacenter=4 cloud=4 GPUs; caps research 4 + release-evals 6 + inference-eval 4 = 14 > 8"
}

# --- (a) quota ------------------------------------------------------------------
case_quota() {
  expect 'research asks for 5 GPUs (cap 4): refused at admission, error names BOTH "exceeded quota" AND "nvidia.com/gpu"'
  expect 'the pod object never exists: get pod returns NotFound'
  local out got
  out="$(pod_yaml research over-cap 5 | kubectl apply -f - 2>&1)"
  show "apply: $out"
  if has "$out" "exceeded quota" && has "$out" "nvidia.com/gpu"; then
    pass "admission refused it, citing the GPU quota"
  else
    fail "expected a GPU quota refusal"
  fi
  got="$(kubectl -n research get pod over-cap 2>&1)"
  has "$got" NotFound && pass "pod was never created" || fail "pod exists: $got"
}

# --- (b) capacity ---------------------------------------------------------------
case_capacity() {
  expect 'high tier holds all 8 GPUs; research (low tier, 0 of 4 used) asks for 1: ADMITTED, then Pending'
  expect 'FailedScheduling event on that pod containing "Insufficient nvidia.com/gpu" (a cap is not a reservation)'
  local uid msg node
  gpu_pods release-evals hold 6
  gpu_pods inference-eval hold 2
  wait_ready release-evals 60 && wait_ready inference-eval 60 || { fail "high-tier holders never Ready"; return; }
  pod_yaml research starved 1 | kubectl apply -f - >/dev/null || { fail "research pod refused at admission"; return; }
  pass "research pod admitted: it is inside its cap"
  uid="$(uid_of research starved)"
  if msg="$(wait_event research "$uid" FailedScheduling 30)"; then
    show "event: $msg"
    has "$msg" "Insufficient nvidia.com/gpu" && pass "Pending for lack of GPUs, not an image pull or a quota" ||
      fail "FailedScheduling for a different reason"
  else
    fail "no FailedScheduling event within 30s"
  fi
  node="$(kubectl -n research get pod starved -o jsonpath='{.spec.nodeName}')"
  [ -z "$node" ] && pass "still unscheduled: a low-tier pod waits, it does not preempt" ||
    fail "scheduled onto $node"
}

# --- (c) preemption -------------------------------------------------------------
case_preemption() {
  expect 'research fills 4 GPUs (low tier), release-evals fills the other 4 (high tier); release-evals asks for 1 more'
  expect 'a "Preempted" EVENT on one of this run'"'"'s research pods, and the high-tier pod reaches Running'
  local uids msg="" i uid
  gpu_pods research filler 4
  wait_ready research 60 || { fail "low-tier fillers never Ready"; return; }
  gpu_pods release-evals hold 4
  wait_ready release-evals 60 || { fail "high-tier holders never Ready"; return; }
  uids="$(kubectl -n research get pods -l "$MARK=true" -o jsonpath='{.items[*].metadata.uid}')"
  pod_yaml release-evals preemptor 1 | kubectl apply -f - >/dev/null
  if wait_ready release-evals 90 "app=preemptor"; then
    pass "high-tier pod Running on a full fleet"
  else
    fail "high-tier pod never Running"
  fi
  # Assert the event, never status Evicted: OOM kills, node loss and manual
  # deletion leave pods looking the same.
  for i in $(seq 1 15); do
    for uid in $uids; do
      msg="$(wait_event research "$uid" Preempted 1)" && break 2
    done
  done
  if [ -n "$msg" ]; then
    show "event: $msg"
    pass "a low-tier pod was preempted"
  else
    fail "no Preempted event on this run's research pods"
  fi
}

# --- (d) network ----------------------------------------------------------------
# kubectl exec returns the remote command's exit code, so curl's is observable.
curl_from() { # <ns> <pod> <url>: prints "<exit> <http_code> <seconds>"
  local t0 code rc
  t0=$SECONDS
  code="$(kubectl -n "$1" exec "$2" -- curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$3" 2>/dev/null)"
  rc=$?
  printf '%s %s %s' "$rc" "${code:-none}" "$((SECONDS - t0))"
}
got_200() { [ "$(cut -d' ' -f1-2 <<<"$1")" = "0 200" ]; }

net_pod() { # <ns> <name> <image> [command]: a small non-GPU pod in the tenant's tier
  local ns="$1" name="$2" image="$3" command="${4:-}" class
  class="$(ns_label "$ns" priority-class)"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $name, namespace: $ns, labels: { $MARK: "true", app: $name } }
spec:
  priorityClassName: $class
  terminationGracePeriodSeconds: 0
  containers:
    - name: c
      image: $image
      ${command:+command: [$command]}
YAML
}

case_network() {
  local url="http://target.release-evals.svc.cluster.local" r i
  expect "release-evals pod -> $url : HTTP 200 (positive control: the target is alive)"
  expect "research pod -> same URL : curl exit 7 (connection refused) within 5s, not exit 28 (timeout)"
  expect "positive control still 200 afterwards"
  net_pod release-evals target nginx:1.27-alpine
  kubectl -n release-evals apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata: { name: target, namespace: release-evals, labels: { $MARK: "true" } }
spec: { selector: { app: target }, ports: [{ port: 80 }] }
YAML
  net_pod release-evals own-probe curlimages/curl:8.11.0 "sleep, infinity"
  net_pod research probe curlimages/curl:8.11.0 "sleep, infinity"
  wait_ready release-evals 120 && wait_ready research 120 || { fail "probe pods never Ready"; return; }

  # A young cluster can fail on DNS or endpoints, and that failure looks exactly
  # like a policy block. Retry the control until it answers; without it, no
  # isolation result means anything.
  for i in $(seq 1 30); do
    r="$(curl_from release-evals own-probe "$url")"
    got_200 "$r" && break
    sleep 1
  done
  show "same-namespace: exit/http/seconds = $r"
  if ! got_200 "$r"; then
    fail "positive control never reached the target; isolation result would be meaningless"
    return
  fi
  pass "positive control: target reachable in its own namespace"

  r="$(curl_from research probe "$url")"
  show "cross-tenant:   exit/http/seconds = $r"
  if [ "${r%% *}" = 7 ] && [ "${r##* }" -lt 5 ]; then
    pass "cross-tenant connection refused promptly by NetworkPolicy"
  else
    fail "expected curl exit 7 in under 5s"
  fi

  r="$(curl_from release-evals own-probe "$url")"
  got_200 "$r" &&
    pass "positive control still 200 after the blocked probe" || fail "positive control lost: $r"
}

# --- (e) overflow ---------------------------------------------------------------
case_overflow() {
  expect 'release-evals (pool any = PREFER datacenter) submits 6 x 1 GPU: 4 on the datacenter node, 2 spill to cloud'
  expect 'a tenant pinned to datacenter (REQUIRED) asks for 1 while datacenter is full: Pending, does NOT spill'
  expect 'its FailedScheduling message cites "didn'"'"'t match Pod'"'"'s node affinity/selector" for the cloud node'
  local placed on_dc on_cloud uid msg node
  gpu_pods release-evals spill 6
  wait_ready release-evals 60 || { fail "release-evals pods never Ready"; return; }
  kubectl -n release-evals get pods -l "$MARK=true" -o wide | sed 's/^/            /'
  placed="$(kubectl -n release-evals get pods -l "$MARK=true" -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n')"
  # Count each pool by name. "6 minus datacenter" would count a pod on any other
  # node as cloud.
  on_dc="$(grep -cxF "$(kubectl get nodes -l "$POOL_LABEL=datacenter" -o jsonpath='{.items[0].metadata.name}')" <<<"$placed")"
  on_cloud="$(grep -cxF "$(kubectl get nodes -l "$POOL_LABEL=cloud" -o jsonpath='{.items[0].metadata.name}')" <<<"$placed")"
  [ "$on_dc" = 4 ] && [ "$on_cloud" = 2 ] && pass "4 on datacenter, 2 spilled to cloud" ||
    fail "split was datacenter=$on_dc cloud=$on_cloud (of 6)"

  # Team N goes through the same code path as teams 1-3: a spec file and onboard().
  onboard "$FIXTURE" >/dev/null || { fail "could not onboard fixture tenant"; return; }
  pod_yaml dc-pinned pinned 1 | kubectl apply -f - >/dev/null || { fail "pinned pod refused"; return; }
  uid="$(uid_of dc-pinned pinned)"
  if msg="$(wait_event dc-pinned "$uid" FailedScheduling 30)"; then
    show "event: $msg"
    has "$msg" "didn't match Pod's node affinity/selector" &&
      pass "pinned pod refused the cloud node by affinity, not by capacity" ||
      fail "no node-affinity reason in the message"
  else
    fail "no FailedScheduling event within 30s"
  fi
  node="$(kubectl -n dc-pinned get pod pinned -o jsonpath='{.spec.nodeName}')"
  [ -z "$node" ] && pass "pinned pod did not spill" || fail "pinned pod landed on $node"
  kubectl delete ns dc-pinned --wait=true >/dev/null
}

# --- (f) escalation -------------------------------------------------------------
# kubectl auth can-i exits 1 when the answer is "no". Under pipefail, piping it
# turns a correct denial into a failure that reads as a security hole. Capture
# the printed answer and compare strings; never branch on its exit code.
can_i() { kubectl auth can-i "$@" --as="$RESEARCH_SA" 2>/dev/null || true; }

check_can() { # <expected yes|no> <description> <can-i args...>
  local want="$1" what="$2" got
  shift 2
  got="$(can_i "$@")"
  [ "$got" = "$want" ] && pass "$what: $got" || fail "$what: expected $want, got '$got'"
}

dry_run_as_tenant() { kubectl create --dry-run=server --as="$RESEARCH_SA" -f - 2>&1; }

case_escalation() {
  expect "as $RESEARCH_SA:"
  expect '  list pods in research = yes; list pods in release-evals = no'
  expect '  patch its own resourcequota = no; create a priorityclass = no; patch its own namespace = no'
  expect '  create a pod at its own tier (tenant-low) = accepted  (positive control for the next line)'
  expect '  create a pod naming tenant-high = denied by policy tenant-entitlement'
  expect '  create a privileged pod = denied by Pod Security'
  local out
  check_can yes "list pods in own namespace"      list pods -n research
  check_can no  "list pods in release-evals"      list pods -n release-evals
  check_can no  "patch own resourcequota"         patch resourcequota/gpu-cap -n research
  check_can no  "create a priorityclass"          create priorityclass
  check_can no  "patch own namespace labels"      patch namespace/research

  # The next two denials are only evidence if the tenant can create an ordinary
  # pod. Otherwise RBAC refuses everything and the denials prove nothing. Failure
  # messages print the actual response rather than guess at its cause.
  out="$(pod_yaml research own-tier 0 | dry_run_as_tenant)"
  has "$out" "created (server dry run)" && pass "own tier accepted" || fail "own tier refused: $out"

  out="$(pod_yaml research borrow-tier 0 tenant-high | dry_run_as_tenant)"
  show "response: $out"
  has "$out" "tenant-entitlement" && has "$out" "entitled to priorityClassName tenant-low" &&
    pass "borrowing tier high denied by the entitlement policy" ||
    fail "not denied by the entitlement policy"

  out="$(pod_yaml research privileged 0 |
    awk '{ print } /^      image:/ { print "      securityContext: { privileged: true }" }' | dry_run_as_tenant)"
  show "response: $out"
  has "$out" "violates PodSecurity" && pass "privileged pod denied by Pod Security" ||
    fail "not denied by Pod Security"
}

# --- main -----------------------------------------------------------------------
run_case() {
  local name="$1" t0=$SECONDS
  printf '\n--- %s ---\n' "$name"
  converge
  "case_$name"
  converge
  printf '    (%ss)\n' "$((SECONDS - t0))"
}

selected=("$@")
[ ${#selected[@]} -gt 0 ] || selected=("${CASES[@]}")
for c in "${selected[@]}"; do
  [[ " ${CASES[*]} " == *" $c "* ]] || die "unknown case '$c'. Cases: ${CASES[*]}"
done

assert_context
check_fleet
for c in "${selected[@]}"; do run_case "$c"; done

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
