#!/bin/bash
# Slack message builders and bot-token sender for release notifications.

# Post a Slack message via chat.postMessage. Reads the JSON payload from stdin.
# Usage: slack_send_with_token "$SLACK_BOT_TOKEN" < message.json
slack_send_with_token() {
    local token="$1"
    local curl_stderr; curl_stderr=$(mktemp)
    if ! curl --fail-with-body -sS -X POST https://api.slack.com/api/chat.postMessage \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json; charset=utf-8" \
        -d @-  2>"$curl_stderr"; then
        echo "curl to chat.postMessage failed:" >&2
        cat "$curl_stderr" >&2
        rm -f "$curl_stderr"
        return 1
    fi
    rm -f "$curl_stderr"
    return 0
}

# Parse a chat.postMessage response (read from stdin). Writes slack_ts and
# slack_url to $GITHUB_OUTPUT when set. Non-zero exit on API error.
# Usage: slack_handle_message_result "$channel_id" "$sent_payload" < response.json
slack_handle_message_result() {
    local channel_id="$1"
    local message="$2"
    local response; response=$(cat)

    if echo "$response" | jq -e '.ok == true' >/dev/null; then
        local slack_ts slack_channel ts_for_url slack_url
        slack_ts=$(echo "$response" | jq -r '.ts')
        slack_channel=$(echo "$response" | jq -r '.channel')
        ts_for_url=$(echo "$slack_ts" | tr -d '.')
        slack_url="https://redis.slack.com/archives/${slack_channel}/p${ts_for_url}"
        if [ -n "${GITHUB_OUTPUT:-}" ]; then
            echo "slack_ts=$slack_ts" >> "$GITHUB_OUTPUT"
            echo "slack_url=$slack_url" >> "$GITHUB_OUTPUT"
        fi
        echo "✅ Slack message sent: $slack_url"
        return 0
    fi

    local error; error=$(echo "$response" | jq -r '.error // "unknown"')
    echo "❌ Failed to send Slack message: $error" >&2
    echo "$response" | jq '.' >&2
    echo "Message content: $message" >&2
    return 1
}

slack_format_success_message() {
    # $1 channel  $2 release_tag  $3 base_url (…/redis-cli)  $4 env  $5 footer
    jq -n --arg channel "$1" --arg tag "$2" --arg base "$3" --arg env "$4" --arg footer "$5" '
    {
      "channel": $channel,
      "icon_emoji": ":redis-circle:",
      "text": (":redis-circle: redis-cli " + $tag + " published (" + $env + ")"),
      "blocks": [
        { "type": "header",
          "text": { "type": "plain_text", "text": ("redis-cli " + $tag + " published (" + $env + ")") } },
        { "type": "section",
          "text": { "type": "mrkdwn",
            "text": ("Install:\n```curl -fsSL " + $base + "/install.sh | REDIS_CLI_VERSION=" + $tag + " sh```") } },
        { "type": "context", "elements": [ { "type": "mrkdwn", "text": $footer } ] }
      ]
    }'
}

slack_format_failure_message() {
    # $1 channel  $2 release_tag  $3 message  $4 env  $5 footer
    jq -n --arg channel "$1" --arg tag "$2" --arg msg "$3" --arg env "$4" --arg footer "$5" '
    {
      "channel": $channel,
      "icon_emoji": ":redis-circle:",
      "text": (":x: redis-cli " + $tag + " release failed (" + $env + ")"),
      "blocks": [
        { "type": "header",
          "text": { "type": "plain_text", "text": ("redis-cli " + $tag + " release failed (" + $env + ")") } },
        { "type": "section", "text": { "type": "mrkdwn", "text": $msg } },
        { "type": "context", "elements": [ { "type": "mrkdwn", "text": $footer } ] }
      ]
    }'
}
