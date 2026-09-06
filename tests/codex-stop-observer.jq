# Test-only canonical view of native Codex hook JSON streams. jq -s accepts
# both JSONL and concatenated objects. Duplicate records do not invent turns;
# conflicting duplicates and missing identities fail rather than count as idle.
if length == 0 then error("no native events") else . end
| map(if (.session_id | type) != "string" or .session_id == ""
         or (.turn_id | type) != "string" or .turn_id == ""
         or (.hook_event_name != "Stop" and .hook_event_name != "UserPromptSubmit")
      then error("invalid native event identity")
      else {session_id, turn_id, hook_event_name,
            message: (if .hook_event_name == "Stop" then .last_assistant_message else .prompt end)} end)
| group_by([.session_id, .turn_id, .hook_event_name])
| map(if (unique | length) != 1 then error("conflicting duplicate native event") else .[0] end)
| if (map(.session_id) | unique | length) != 1 then error("multiple primary sessions") else . end
| {session_id: .[0].session_id,
   events: .,
   stopped: [ .[] | select(.hook_event_name == "Stop") | .turn_id ],
   submitted: [ .[] | select(.hook_event_name == "UserPromptSubmit") | .turn_id ],
   handled: [ .[] | select(.hook_event_name == "Stop" and .message == "HANDLED_IDLE") | .turn_id ]}
