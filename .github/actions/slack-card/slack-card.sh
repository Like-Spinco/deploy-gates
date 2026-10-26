#!/usr/bin/env bash
# slack-card.sh <state>: posts the release card, or redraws it when SLACK_TS is set.
#   states: start, running:<Stage>, waiting:<Stage>, done, failed:<Stage>, cancelled
# Env: SLACK_TOKEN, SLACK_CHANNEL, SLACK_TS, SLACK_META (JSON: app, environment, stages, sha, subject, author, actor, run_url),
#   APPROVE_URL, JOB_URL (the current stage), LINKS (JSON: stage -> URL), NOTE (context line).
# Writes ts= on a post. Slack trouble never fails a deploy: every error is a warning.
set -uo pipefail

state=${1:?state}
[ -n "${SLACK_TOKEN:-}" ] && [ -n "${SLACK_CHANNEL:-}" ] || { echo "Slack is not configured; skipped"; exit 0; }

meta_json=${SLACK_META:-}
[ -n "$meta_json" ] || meta_json='{}'
meta() { jq -r --arg k "$1" '.[$k] // ""' <<<"$meta_json"; }
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }
api() { curl -sS --max-time 15 -X POST "https://slack.com/api/$1" -H "Authorization: Bearer $SLACK_TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" --data "$2"; }

app=$(meta app) env=$(meta environment) sha=$(meta sha) run_url=$(meta run_url)
subject=$(esc "$(meta subject)") author=$(esc "$(meta author)") actor=$(esc "$(meta actor)")
read -ra stages <<<"$(meta stages)"
[ ${#stages[@]} -gt 0 ] || stages=(Deploy)

current="" icon="" header=""
case "$state" in
  start) current=${stages[0]} icon="🔄" header="🚀 Deploying" ;;
  running:Switch) current=Switch icon="🔄" header="🔀 Switching traffic" ;;
  running:*) current=${state#running:} icon="🔄" header="🚀 Deploying" ;;
  waiting:*) current=${state#waiting:} icon="⏳" header="⏳ Waiting for approval" ;;
  done) header="🟢 Deployed" ;;
  cancelled) header="⚪ Cancelled" ;;
  failed:*) current=${state#failed:} icon="❌" header="🔴 Failed at ${state#failed:}" ;;
  *) echo "::warning title=Slack::unknown state $state"; exit 0 ;;
esac

links_json=${LINKS:-}
[ -n "$links_json" ] || links_json='{}'
line="" seen=""
for s in "${stages[@]}"; do
  if [ "$state" = "done" ]; then
    mark="✅"
  elif [ "$state" = cancelled ]; then
    mark="⚪"
  elif [ "$s" = "$current" ]; then
    mark=$icon seen=1
  elif [ -n "$seen" ] || [ -z "$current" ]; then
    mark="▫️"
  else
    mark="✅"
  fi
  url=$(jq -r --arg s "$s" '.[$s] // ""' <<<"$links_json")
  [ "$s" = "$current" ] && [ -n "${JOB_URL:-}" ] && url=$JOB_URL
  if [ "$state" = "waiting:$s" ] && [ -n "${APPROVE_URL:-}" ]; then
    label="*<$APPROVE_URL|Approve>*"
  elif [ -n "$url" ]; then
    label="<$url|$s>"
  elif [ "$mark" = "✅" ] || [ "$mark" = "❌" ] || [ "$s" = "$current" ]; then
    label="<$run_url|$s>"
  else
    label=$s
  fi
  line+="${line:+   }$mark $label"
done

repo_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}"
title="$header: *$app → $env*"
if [ -n "$sha" ]; then
  commit="<$repo_url/commit/$sha|\`${sha:0:7}\`> $subject${author:+ — $author}"
else
  commit="Manual run${actor:+ by $actor}"
fi

payload=$(jq -nc --arg channel "$SLACK_CHANNEL" --arg ts "${SLACK_TS:-}" --arg text "$header: $app → $env ${sha:0:7}" \
  --arg title "$title" --arg commit "$commit" --arg line "$line" --arg note "${NOTE:-}" '
  {channel: $channel, text: $text, unfurl_links: false, unfurl_media: false,
   blocks: ([
     {type: "section", text: {type: "mrkdwn", text: ($title + "\n" + $commit)}},
     {type: "section", text: {type: "mrkdwn", text: $line}}
   ] + (if $note == "" then [] else [{type: "context", elements: [{type: "mrkdwn", text: $note}]}] end))}
  + (if $ts == "" then {} else {ts: $ts} end)')
[ -n "$payload" ] || { echo "::warning title=Slack::could not build the message"; exit 0; }

method=chat.postMessage
[ -n "${SLACK_TS:-}" ] && method=chat.update
response=$(api "$method" "$payload") || { echo "::warning title=Slack::$method request failed"; exit 0; }
if [ "$(jq -r .ok <<<"$response")" != true ]; then
  echo "::warning title=Slack::$method: $(jq -r '.error // "unknown error"' <<<"$response")"
  exit 0
fi
if [ -z "${SLACK_TS:-}" ]; then
  echo "ts=$(jq -r .ts <<<"$response")" >>"${GITHUB_OUTPUT:-/dev/null}"
fi
echo "Slack: $state"

# chat.update never notifies, so these states get a thread reply naming every channel member; @channel is silent in threads.
release="*$app → $env*${sha:+ \`${sha:0:7}\`}"
case "$state" in
  waiting:*) note="⏳ $release is waiting for approval${APPROVE_URL:+: *<$APPROVE_URL|Approve>*}" ;;
  done) note="🟢 $release deployed" ;;
  cancelled) note="⚪ $release cancelled" ;;
  failed:*) note="🔴 $release failed at ${state#failed:}: <${JOB_URL:-$run_url}|View in GitHub Actions>" ;;
  *) exit 0 ;;
esac
[ -n "${SLACK_TS:-}" ] || exit 0

me=$(curl -sS --max-time 15 -H "Authorization: Bearer $SLACK_TOKEN" https://slack.com/api/auth.test | jq -r '.user_id // ""')
members=$(curl -sS --max-time 15 -G -H "Authorization: Bearer $SLACK_TOKEN" https://slack.com/api/conversations.members \
  --data-urlencode "channel=$SLACK_CHANNEL" --data-urlencode limit=200)
if [ "$(jq -r .ok <<<"$members")" = true ]; then
  note="$(jq -r --arg me "$me" '[.members[] | select(. != $me) | "<@\(.)>"] | join(" ")' <<<"$members") $note"
else
  echo "::warning title=Slack::conversations.members: $(jq -r '.error // "unknown error"' <<<"$members"); the reply mentions nobody"
fi

reply=$(jq -nc --arg channel "$SLACK_CHANNEL" --arg ts "$SLACK_TS" --arg text "$note" \
  '{channel: $channel, thread_ts: $ts, text: $text, unfurl_links: false, unfurl_media: false}')
response=$(api chat.postMessage "$reply") || { echo "::warning title=Slack::thread reply failed"; exit 0; }
[ "$(jq -r .ok <<<"$response")" = true ] || echo "::warning title=Slack::thread reply: $(jq -r '.error // "unknown error"' <<<"$response")"
