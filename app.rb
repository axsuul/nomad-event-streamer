# Forwards HashiCorp Nomad event stream to Discord

require "active_support"
require "active_support/core_ext"
require "http"

require_relative "lib/ndjson"

# Returns current timestamp in same integer format as Nomad with nanoseconds
def current_timestamp
  (Time.now.to_f.to_s.split(".") | ["000"]).join("").to_i
end

def parse_env_list(key)
  ENV[key]&.split(",")&.map(&:strip) || []
end

NOMAD_ADDR = ENV["NOMAD_ADDR"] || "http://localhost:4646"
NOMAD_API_BASE_URL = "#{NOMAD_ADDR}/v1".freeze

DISCORD_WEBHOOK_URL = ENV["DISCORD_WEBHOOK_URL"]

# https://www.nomadproject.io/api-docs/allocations#events
TASK_EVENT_TYPE_ALLOWLIST = parse_env_list("TASK_EVENT_TYPE_ALLOWLIST")
TASK_EVENT_TYPE_DENYLIST = parse_env_list("TASK_EVENT_TYPE_DENYLIST")

# Retrieve last index so we now which events are older
agent_response = HTTP.get("#{NOMAD_API_BASE_URL}/agent/self")
started_at = current_timestamp
starting_index = JSON.parse(agent_response.body).dig("stats", "raft", "last_log_index")&.to_i

puts "Starting index: #{starting_index}"

# Used for tracking each job task
task_metadata = Hash.new { |h, k| h[k] = {} }

event_stream_body = HTTP.get("#{NOMAD_API_BASE_URL}/event/stream").body

ndjson = NDJSON.new

loop do
  parsed_resources_collection = ndjson.parse_partial(event_stream_body.readpartial)

  parsed_resources_collection.each do |parsed_resource|
    # An empty JSON object is to signal heartbeat
    if parsed_resource.empty?
      puts "Heartbeat detected"

      next
    end

    index = parsed_resource.dig("Index")

    # Ignore older events
    next if starting_index >= index

    puts "Current index: #{index}"

    parsed_resource.dig("Events").each do |event_resource|
      # For debugging purposes
      # puts event_resource

      case event_resource.dig("Topic")
      when "Allocation"
        allocation_resource = event_resource.dig("Payload", "Allocation")
        job_id = allocation_resource.dig("JobID")

        puts "job_id: #{job_id}"

        task_state_resources = allocation_resource.dig("TaskStates")

        unless task_state_resources
          puts "No task state resources for #{job_id}, skipping!"

          next
        end

        task_state_resources.each do |task_id, task_state_resource|
          # Ignore connect proxies
          next if task_id.match(/connect-proxy/)

          task_identifier = "#{job_id}.#{task_id}"
          task_events_last_handled_at = task_metadata[task_identifier][:last_event_timestamp] || started_at

          most_recent_event_timestamp = nil

          task_state_resource.dig("Events").each do |task_event_resource|
            task_event_type = task_event_resource.dig("Type")

            next if TASK_EVENT_TYPE_DENYLIST.include?(task_event_type)

            if TASK_EVENT_TYPE_ALLOWLIST.any? && !TASK_EVENT_TYPE_ALLOWLIST.include?(task_event_type)
              next
            end

            # UNIX timestamp with nine additional digits appended to represent nanoseconds
            timestamp = task_event_resource.dig("Time")

            if most_recent_event_timestamp.nil? || timestamp > most_recent_event_timestamp
              most_recent_event_timestamp = timestamp
            end

            # Ignore events we've already seen or events that happened before we started monitoring
            next if timestamp <= task_events_last_handled_at

            task_event_display_message = task_event_resource.dig("DisplayMessage")
            task_event_details = task_event_resource.dig("Details")

            content = "**#{task_identifier}** task is **#{task_event_type}**"
            description = task_event_display_message
            description << "```#{task_event_details}```" if task_event_details.any?
            is_critical =
              case task_event_type
              when "Terminated"
                task_event_details["oom_killed"] == "true" || task_event_details["exit_code"] != 0
              else
                false
              end

            embed = {
              description: description,
            }

            # Add red border if event type is critical
            embed[:color] = 15158332 if is_critical

            puts "Sending to Discord: #{content}"

            HTTP.post(DISCORD_WEBHOOK_URL,
              json: {
                content: content,
                embeds: [embed],
              },
            )
          end

          # Track most recent event timestamp for task so we don't re-do events we've already seen next time around
          if most_recent_event_timestamp && most_recent_event_timestamp > task_events_last_handled_at
            task_metadata[task_identifier][:last_event_timestamp] = most_recent_event_timestamp
          end
        end
      end
    end
  end
end


