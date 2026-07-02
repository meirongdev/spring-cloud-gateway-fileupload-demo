#!/bin/sh
# Runs inside the loadtester pod. Uploads $1 through the gateway and prints
# "http_code|servedBy|protocol" on one line.
GATEWAY_URL="http://gateway413.demo413.svc.cluster.local:8080/api/file/upload"
out=$(curl -s -w "|%{http_code}" -F module=DEPOSIT \
  -F "file=@$1;filename=t.png;type=image/png" "$GATEWAY_URL")
code=${out##*|}
body=${out%|*}
sb=$(echo "$body" | grep -o '"servedBy":"[^"]*"' | cut -d'"' -f4)
pr=$(echo "$body" | grep -o '"protocol":"[^"]*"' | cut -d'"' -f4)
echo "${code}|${sb:--}|${pr:--}"
