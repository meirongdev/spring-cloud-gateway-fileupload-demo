#!/bin/sh
# Runs INSIDE the cluster (loadtester pod) so requests actually go through
# kube-proxy's Service load-balancing across whatever gateway413 pods exist —
# a `kubectl port-forward` from the host would pin to a single pod and never
# exercise that load-balancing at all.
set -eu

GATEWAY_URL="http://gateway413.demo413.svc.cluster.local:8080/api/file/upload"
LABEL="${1:-run}"

head -c 500000   /dev/urandom > /tmp/small.bin
head -c 3000000  /dev/urandom > /tmp/medium.bin
head -c 12000000 /dev/urandom > /tmp/large.bin

run_batch() {
  file=$1
  count=$2
  name=$3
  echo "=== $LABEL / $name (n=$count) ==="
  : > /tmp/codes.txt
  i=0
  while [ "$i" -lt "$count" ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' \
      -F "module=DEPOSIT" \
      -F "file=@${file};filename=test.png;type=image/png" \
      "$GATEWAY_URL")
    echo "$code" >> /tmp/codes.txt
    i=$((i + 1))
  done
  sort /tmp/codes.txt | uniq -c
}

run_batch /tmp/small.bin  20 "500KB  (under gateway's accidental 1MB default)"
run_batch /tmp/medium.bin 20 "3MB    (over gateway's 1MB default, under backend's 10MB business limit)"
run_batch /tmp/large.bin  20 "12MB   (over both limits)"
