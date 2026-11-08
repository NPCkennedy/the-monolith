#!/usr/bin/env bash
# M5: remove the hand-applied cert-manager copy; keep the Argo-managed cert-manager-operator.
# Run AFTER M6. Never touches CRDs. Add cert-manager-cert-manager-tokenrequest to RB_CM
# only if its subject is SA "cert-manager" (pre-check).
set -euo pipefail
NS=cert-manager

DEPLOYS="cert-manager cert-manager-cainjector cert-manager-webhook"
SVCS="cert-manager cert-manager-cainjector cert-manager-webhook"
SAS="cert-manager cert-manager-cainjector cert-manager-webhook"
ROLES_KS="cert-manager:leaderelection cert-manager-cainjector:leaderelection"
ROLES_CM="cert-manager-tokenrequest cert-manager-webhook:dynamic-serving"
RB_CM="cert-manager-tokenrequest cert-manager-webhook:dynamic-serving cert-manager-cert-manager-tokenrequest"
CRS=$(kubectl get clusterrole -o name | grep '/cert-manager' | grep -v operator | cut -d/ -f2)
CRBS=$(kubectl get clusterrolebinding -o name | grep '/cert-manager' | grep -v operator | cut -d/ -f2)

# ---- Stage 1: backup (read only) ----
{
  kubectl get validatingwebhookconfiguration/cert-manager-webhook mutatingwebhookconfiguration/cert-manager-webhook -o json
  for d in $DEPLOYS; do kubectl -n $NS get deploy "$d" -o json; done
  for s in $SVCS;    do kubectl -n $NS get svc "$s" -o json; done
  for s in $SAS;     do kubectl -n $NS get sa "$s" -o json; done
  for r in $ROLES_KS; do kubectl -n kube-system get role "$r" -o json; kubectl -n kube-system get rolebinding "$r" -o json; done
  for r in $ROLES_CM; do kubectl -n $NS get role "$r" -o json; done
  for r in $RB_CM;    do kubectl -n $NS get rolebinding "$r" -o json; done
  for r in $CRS;  do kubectl get clusterrole "$r" -o json; done
  for r in $CRBS; do kubectl get clusterrolebinding "$r" -o json; done
} | python3 -c '
import json,sys
dec=json.JSONDecoder(); s=sys.stdin.read(); i=0; items=[]
while i<len(s):
    while i<len(s) and s[i].isspace(): i+=1
    if i>=len(s): break
    o,i=dec.raw_decode(s,i); m=o["metadata"]
    for k in ("resourceVersion","uid","creationTimestamp","managedFields","generation"): m.pop(k,None)
    o.pop("status",None)
    if o["kind"]=="Service":
        o["spec"].pop("clusterIP",None); o["spec"].pop("clusterIPs",None)
    items.append(o)
json.dump({"apiVersion":"v1","kind":"List","items":items},sys.stdout,indent=1)
print(len(items),"objects backed up",file=sys.stderr)' > ~/cm-original-backup.json
chmod 600 ~/cm-original-backup.json
read -rp "Backup done. Continue to delete? (yes) " a; [ "$a" = yes ] || exit 0

# ---- Stage 2: delete, webhooks first ----
kubectl delete validatingwebhookconfiguration cert-manager-webhook
kubectl delete mutatingwebhookconfiguration cert-manager-webhook
kubectl -n $NS delete deploy $DEPLOYS
kubectl -n $NS delete svc $SVCS
kubectl -n $NS delete sa $SAS
for r in $ROLES_KS; do kubectl -n kube-system delete role "$r"; kubectl -n kube-system delete rolebinding "$r"; done
for r in $ROLES_CM; do kubectl -n $NS delete role "$r"; done
for r in $RB_CM;    do kubectl -n $NS delete rolebinding "$r"; done
kubectl delete clusterrolebinding $CRBS
kubectl delete clusterrole $CRS
kubectl get crd | grep -c cert-manager.io   # must still print 6

# ---- Stage 3: verify takeover (re-run until both leases show operator pods) ----
sleep 90
kubectl -n kube-system get lease | grep -i cert
kubectl -n $NS get pods
kubectl -n kube-system get certificate spencer-kennedy-wildcard

# ---- Stage 4: force renewal (same as cmctl renew) ----
kubectl -n kube-system patch certificate spencer-kennedy-wildcard --subresource=status --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/status/conditions/-\",\"value\":{\"type\":\"Issuing\",\"status\":\"True\",\"reason\":\"ManuallyTriggered\",\"message\":\"M5 takeover test\",\"lastTransitionTime\":\"$(date -u +%FT%TZ)\"}}]"
# then watch (DNS-01 takes 1-3 min):
#   kubectl -n kube-system get certificaterequest
#   kubectl -n kube-system get certificate spencer-kennedy-wildcard -o jsonpath='{.status.notAfter}{"\n"}'
# Rollback: kubectl apply -f ~/cm-original-backup.json
