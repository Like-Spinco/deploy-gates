#!/usr/bin/env bash
# rerun-job.sh <owner/repo> <run-id> <job>: waits for the run to finish, re-runs the job and its dependents, waits for them.
#   <job> matches a name that starts with it, or a called workflow's job named "<caller> / <job>".
set -euo pipefail

repo=$1 run_id=$2 prefix=$3
run="repos/$repo/actions/runs/$run_id"
url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/$run_id"

result=failed attempt="" new_attempt="" job_url=""
report() {
  {
    echo "### $prefix: $result"
    echo "- Run: $url/attempts/${new_attempt:-$attempt}"
    [ -z "$job_url" ] || echo "- $prefix job: $job_url"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}
trap report EXIT

wait_run() {
  local status
  for _ in $(seq "${1:-120}"); do
    status=$(gh api "$run" --jq .status)
    [ "$status" = completed ] && return
    sleep 5
  done
  echo "::error::the run is still $status"
  exit 1
}

job_id() {
  gh api "$run/jobs?filter=latest&per_page=100" | jq -r --arg p "$prefix" '[.jobs[] | select((.name | startswith($p)) or (.name | endswith(" / " + $p)))][0].id // empty'
}

echo "Run: $url"
wait_run
attempt=$(gh api "$run" --jq .run_attempt)
job=$(job_id)
[ -n "$job" ] || { echo "::error::no $prefix job in the run"; exit 1; }
gh api -X POST "repos/$repo/actions/jobs/$job/rerun" --silent

for _ in $(seq 24); do
  new_attempt=$(gh api "$run" --jq .run_attempt)
  [ "$new_attempt" -gt "$attempt" ] && break
  sleep 5
done
[ "$new_attempt" -gt "$attempt" ] || { new_attempt=""; echo "::error::the re-run did not start"; exit 1; }
echo "Attempt: $url/attempts/$new_attempt"

new_job=$(job_id)
if [ -n "$new_job" ] && [ "$new_job" != "$job" ]; then
  job_url="$url/job/$new_job"
  echo "$prefix job: $job_url"
fi

wait_run 340
conclusion=$(gh api "$run" --jq .conclusion)
result=$conclusion
[ "$conclusion" = success ] || { echo "::error::the re-run ended $conclusion"; exit 1; }
