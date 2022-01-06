# Forwards HashiCorp Nomad event stream to Discord

require "active_support"
require "active_support/core_ext"
require "http"

NOMAD_ADDR = ENV["NOMAD_ADDR"] || "http://localhost:4646"
NOMAD_API_BASE_URL = "#{NOMAD_ADDR}/v1".freeze

# Returns current timestamp in same integer format as Nomad with nanoseconds
def current_timestamp
  (Time.now.to_f.to_s.split(".") | ["000"]).join("").to_i
end

def parse_env_list(key)
  ENV[key]&.split(",")&.map(&:strip) || []
end

DISCORD_WEBHOOK_URL = ENV["DISCORD_WEBHOOK_URL"]
EVENT_TYPE_ALLOWLIST = parse_env_list("EVENT_TYPE_ALLOWLIST")
EVENT_TYPE_DENYLIST = parse_env_list("EVENT_TYPE_DENYLIST")
TASK_EVENT_TYPE_ALLOWLIST = parse_env_list("TASK_EVENT_TYPE_ALLOWLIST")
TASK_EVENT_TYPE_DENYLIST = parse_env_list("TASK_EVENT_TYPE_DENYLIST")

# Retrieve last index so we now which events are older
agent_response = HTTP.get("#{NOMAD_API_BASE_URL}/agent/self")
started_at = current_timestamp
last_index = JSON.parse(agent_response.body).dig("stats", "raft", "last_log_index")&.to_i

puts "Last index: #{last_index}"

# Used for tracking each job task
# task_metadata = Hash.new { |h, job_id| h[job_id] = Hash.new { |hh, task_id| hh[task_id] = {} } }
task_metadata = Hash.new { |h, k| h[k] = {} }

event_stream_body = HTTP.get("#{NOMAD_API_BASE_URL}/event/stream").body

previous_json_part = ""

loop do
  # The incoming stream can be incomplete JSON but because it's using ndjson format we know when it begins and ends
  json_parts = event_stream_body.readpartial.split("\n")

  parsed_resources_collection = []

  json_parts.each do |json_part|
    parsed_resource = JSON.parse(previous_json_part + json_part)

    # Previous part was parsed correctly so we can start on next part
    previous_json_part = ""

    parsed_resources_collection << parsed_resource
  rescue JSON::ParserError
    # Still incomplete JSON so add to previous part
    previous_json_part << json_part
  end

  parsed_resources_collection.each do |parsed_resource|
    next if parsed_resource.empty?

    index = parsed_resource.dig("Index")

    # Ignore older events
    next if last_index >= index

    parsed_resource.dig("Events").each do |event_resource|
      # For debugging purposes
      # puts event_resource

      case event_resource.dig("Topic")
      when "Allocation"
        allocation_resource = event_resource.dig("Payload", "Allocation")
        job_id = allocation_resource.dig("JobID")

        task_state_resources = allocation_resource.dig("TaskStates")

        unless task_state_resources
          puts event_resource.inspect

          next
        end

        task_state_resources.each do |task_id, task_state_resource|
          # Don't care about connect proxies
          next if task_id.match(/connect-proxy/)

          task_identifier = "#{job_id}.#{task_id}"
          task_events_last_handled_at = task_metadata[task_identifier][:last_event_timestamp] || started_at

          puts "#{task_identifier}, task_events_last_handled_at: #{task_events_last_handled_at}"

          most_recent_event_timestamp = nil

          task_state_resource.dig("Events").each do |task_event_resource|
            task_event_type = task_event_resource.dig("Type")

            next if TASK_EVENT_TYPE_DENYLIST.include?(task_event_type)

            if TASK_EVENT_TYPE_ALLOWLIST.any? && !TASK_EVENT_TYPE_ALLOWLIST.include?(task_event_type)
              next
            end

            # Remove last nine digits from timestamp since it has nanosecond precision
            timestamp = task_event_resource.dig("Time")

            if most_recent_event_timestamp.nil? || timestamp > most_recent_event_timestamp
              puts "setting msot recent timestamp"
              most_recent_event_timestamp = timestamp
            end

            # Ignore events we've already seen or events that happened before we started monitoring
            next if timestamp <= task_events_last_handled_at

            task_event_display_message = task_event_resource.dig("DisplayMessage")
            task_event_details = task_event_resource.dig("Details")

            content = "**#{task_identifier}** task is **#{task_event_type}**: #{task_event_display_message} #{timestamp}"
            content << "```#{task_event_details}```" if task_event_details.any?

            HTTP.post(DISCORD_WEBHOOK_URL,
              json: {
                content: content,
              },
            )
          end

          puts "most recent event itmestamp: #{most_recent_event_timestamp}"
          puts "task_events_last_handled_at: #{task_events_last_handled_at}"

          if most_recent_event_timestamp && most_recent_event_timestamp > task_events_last_handled_at
            task_metadata[task_identifier][:last_event_timestamp] = most_recent_event_timestamp
          end

          puts "#{task_identifier}, set last_event_timestamp to: #{task_metadata[task_identifier][:last_event_timestamp]}"
        end
      end

      # event_type = event_resource.dig("Type")

      # payload_resource = event_resource.dig("Payload")

    end
  end
end


