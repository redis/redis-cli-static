#!/bin/bash
# Slack message builders for release notifications: a success message with the
# install command, or a failure message with the reason.

slack_format_success_message() {
    # $1 release_tag  $2 base_url (…/redis-cli)  $3 env  $4 footer
    jq -n --arg tag "$1" --arg base "$2" --arg env "$3" --arg footer "$4" '
    {
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
    # $1 release_tag  $2 message  $3 env  $4 footer
    jq -n --arg tag "$1" --arg msg "$2" --arg env "$3" --arg footer "$4" '
    {
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
