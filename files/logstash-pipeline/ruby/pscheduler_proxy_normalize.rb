require 'json'

def filter(event)
  message = event.get("message") || event.get("[event][original]") || event.get("[raw_message]")
  return [event] unless message.is_a?(String)

  begin
    # Quickly check if we can trim out problematic nested content manually
    # Do NOT try full parse if there's clearly an embedded JSON string in "diags"
    if message.include?('"type":"throughput"') && message.include?('"diags":"')
      # Attempt to remove result-full diags content using a loose regex
      cleaned = message.gsub(/"diags"\s*:\s*".*?\{\\n.*?\\n\s*\\\"end\\\":/m, '"diags":"[removed_for_parsing]"')
      parsed = JSON.parse(cleaned)
    else
      parsed = JSON.parse(message)
    end

    event.set("pscheduler_event", parsed)

  rescue => e
    event.tag("json_parse_error")
    event.set("json_parse_error_message", e.message)
  end

  return [event]
end

