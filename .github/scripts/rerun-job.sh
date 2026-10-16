#!/usr/bin/env bash
# rerun-job.sh <owner/repo> <run-id> <job-name-prefix>: waits for the run to finish, re-runs the job, waits for it.
set -euo pipefail

repo=$1 run_id=$2 prefix=$3
run="repos/$repo/actions/runs/$run_id"

wait_run() {
  local status
  for _ in $(seq 120); do
    status=$(gh api "$run" --jq .status)
    [ "$status" = completed ] && return
    sleep 5
  done
  echo "::error::the run is still $status"
  exit 1
}

wait_run
attempt=$(gh api "$run" --jq .run_attempt)
job=$(gh api "$run/jobs?filter=latest&per_page=100" | jq -r --arg p "$prefix" '[.jobs[] | select(.name | startswith($p))][0].id // empty')
[ -n "$job" ] || { echo "::error::no $prefix job in the run"; exit 1; }
gh api -X POST "repos/$repo/actions/jobs/$job/rerun" --silent

for _ in $(seq 24); do
  [ "$(gh api "$run" --jq .run_attempt)" -gt "$attempt" ] && break
  sleep 5
done
wait_run
conclusion=$(gh api "$run" --jq .conclusion)
[ "$conclusion" = success ] || { echo "::error::the re-run ended $conclusion"; exit 1; }
