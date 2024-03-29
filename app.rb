# Forwards HashiCorp Nomad event stream to Discord

require "active_support"
require "active_support/core_ext"
require "http"

require_relative "lib/ndjson"

# Returns current timestamp in same integer format as Nomad with nanoseconds
def current_timestamp(format: nil)
  timestamp = Time.now.to_f

  case format
  when :nomad
    # Number of subseconds can vary depending on system
    seconds, subseconds = timestamp.to_s.split(".")

    # Ensure there's always 9 additional digits representing nanoseconds after the timestamp representing seconds
    "#{seconds}#{subseconds}#{'0' * (9 - subseconds.length)}".to_i
  else
    timestamp.to_i
  end
end

def parse_env_list(key)
  ENV[key]&.split(",")&.map(&:strip) || []
end

def send_api_request(http_method, *args)
  http = HTTP

  if (token = NOMAD_TOKEN)
    http = http.headers("X-Nomad-Token" => token)
  end

  http.public_send(http_method, *args)
end

NOMAD_ADDR = ENV["NOMAD_ADDR"] || "http://localhost:4646"
NOMAD_API_BASE_URL = "#{NOMAD_ADDR}/v1".freeze

# Specify which namespace to stream events for. Set this to "*" to include all namespaces
NOMAD_NAMESPACE = ENV["NOMAD_NAMESPACE"].presence

# Specify a token to be used for authentication
NOMAD_TOKEN = ENV["NOMAD_TOKEN"].presence

# Will automatically exit if number of seconds have elapsed past threshold since last heartbeat
HEARTBEAT_UNDETECTED_EXIT_THRESHOLD = ENV["HEARTBEAT_UNDETECTED_EXIT_THRESHOLD"].presence&.to_i

# Where Discord events should be sent
DISCORD_WEBHOOK_URL = ENV["DISCORD_WEBHOOK_URL"].presence

# Where Slack events should be sent
SLACK_WEBHOOK_URL = ENV["SLACK_WEBHOOK_URL"].presence

# Comma separated event types to allow or deny (ignore)
# See for possible event types: https://www.nomadproject.io/api-docs/allocations#events
TASK_EVENT_TYPE_ALLOWLIST = parse_env_list("TASK_EVENT_TYPE_ALLOWLIST")
TASK_EVENT_TYPE_DENYLIST = parse_env_list("TASK_EVENT_TYPE_DENYLIST")

# Retrieve last index so we know which events are older
agent_response = send_api_request(:get, "#{NOMAD_API_BASE_URL}/agent/self")
starting_index = JSON.parse(agent_response.body).dig("stats", "raft", "last_log_index")&.to_i

unless starting_index
  puts "Unable to determine starting index, ensure NOMAD_ADDR is pointing to server and not client!"

  exit 1
end

started_at = current_timestamp(format: :nomad)
heartbeat_detected_at = current_timestamp

puts "Starting index: #{starting_index}"

# Used for tracking each job task
task_metadata = Hash.new { |h, k| h[k] = {} }

event_stream_params = {}
event_stream_params[:namespace] = NOMAD_NAMESPACE if NOMAD_NAMESPACE
event_stream_body = HTTP.get("#{NOMAD_API_BASE_URL}/event/stream", params: event_stream_params).body
event_stream_body = send_api_request(:get, "#{NOMAD_API_BASE_URL}/event/stream", params: event_stream_params).body

ndjson = NDJSON.new

if HEARTBEAT_UNDETECTED_EXIT_THRESHOLD
  # Check for heartbeat every second to determine if we need to exit
  Thread.new do
    loop do
      seconds_since_last_heartbeat = current_timestamp - heartbeat_detected_at

      if seconds_since_last_heartbeat > HEARTBEAT_UNDETECTED_EXIT_THRESHOLD
        puts "Heartbeat undetected for #{seconds_since_last_heartbeat} " \
          "#{'second'.pluralize(seconds_since_last_heartbeat)} " \
          "(threshold: #{HEARTBEAT_UNDETECTED_EXIT_THRESHOLD}), exiting..."

        exit 1
      end

      sleep 1
    end
  end
end

loop do
  parsed_resources_collection = ndjson.parse_partial(event_stream_body.readpartial)

  parsed_resources_collection.each do |parsed_resource|
    # An empty JSON object is to signal heartbeat
    if parsed_resource.empty?
      puts "Heartbeat detected"

      heartbeat_detected_at = current_timestamp

      next
    end

    index = parsed_resource.dig("Index")

    # Ignore older events
    next if starting_index >= index

    puts "Current index: #{index}"

    parsed_resource.dig("Events").each do |event_resource|
      # https://www.nomadproject.io/api-docs/events#event-topics
      case event_resource.dig("Topic")
      when "Allocation"
        allocation_resource = event_resource.dig("Payload", "Allocation")
        namespace = allocation_resource.dig("Namespace")
        node_name = allocation_resource.dig("NodeName")
        job_id = allocation_resource.dig("JobID")

        task_state_resources = allocation_resource.dig("TaskStates")

        next unless task_state_resources

        task_state_resources.each do |task_id, task_state_resource|
          # Ignore connect proxies
          next if task_id.match(/connect-proxy/)

          namespace_identifier = "#{namespace}/" unless namespace == "default"
          task_identifier = "#{namespace_identifier}#{job_id}.#{task_id}"
          task_events_latest_timestamp_cached = task_metadata[task_identifier][:latest_timestamp] || started_at
          task_events_latest_timestamp = nil
          task_events = task_state_resource.dig("Events")

          puts "#{task_identifier}: #{task_events.size} #{'event'.pluralize(task_events.size)} detected"

          task_events.each do |task_event_resource|
            task_event_type = task_event_resource.dig("Type")

            # UNIX timestamp with nine additional digits appended to represent nanoseconds
            timestamp = task_event_resource.dig("Time")

            # Track latest timestamp across all events
            if task_events_latest_timestamp.nil? || timestamp > task_events_latest_timestamp
              task_events_latest_timestamp = timestamp
            end

            # Ignore events we've already seen or events that happened before we started monitoring
            if timestamp <= task_events_latest_timestamp_cached
              puts "#{task_identifier}: \"#{task_event_type}\" event skipped due to being older"

              next
            end

            if TASK_EVENT_TYPE_DENYLIST.include?(task_event_type)
              puts "#{task_identifier}: \"#{task_event_type}\" event skipped due to denylist"

              next
            end

            if TASK_EVENT_TYPE_ALLOWLIST.any? && !TASK_EVENT_TYPE_ALLOWLIST.include?(task_event_type)
              puts "#{task_identifier}: \"#{task_event_type}\" event skipped due to allowlist"

              next
            end

            task_event_display_message = task_event_resource.dig("DisplayMessage")
            task_event_details = task_event_resource.dig("Details")
            subject = "**#{task_identifier}** task is **#{task_event_type}** on **#{node_name}** node"
            description = task_event_display_message

            # Format event details as JSON with any double quotes in values converted to single quotes so they aren't
            # escaped in the output
            if task_event_details.any?
              task_event_details_json = task_event_details.transform_values { |v| v.gsub("\"", "'") }.to_json

              # New line needed in Slack to render correctly
              description << "\n```#{task_event_details_json}```"
            end

            state =
              case task_event_type
              when "Restart Signaled"
                if task_event_details.dig("restart_reason")&.match?(/unhealthy/)
                  :failure
                else
                  :success
                end
              when "Terminated"
                if task_event_details.dig("oom_killed") == "true"
                  :failure
                else
                  task_event_details.dig("exit_code") == "0" ? :success : :failure
                end
              end

            delivered_destinations = []

            if DISCORD_WEBHOOK_URL
              embed = {
                description: description,
              }

              # Change border of embed depending on state. Colors are in decimal format:
              # https://www.mathsisfun.com/hexadecimal-decimal-colors.html
              case state
              when :failure
                # Red
                embed[:color] = 15158332
              when :success
                # Green
                embed[:color] = 3066993
              end

              HTTP.post(DISCORD_WEBHOOK_URL,
                json: {
                  content: subject,
                  embeds: [embed],
                },
              )

              delivered_destinations << "Discord"
            end

            if SLACK_WEBHOOK_URL
              attachment = {
                mrkdwn_in: ["text"],
                text: description,

                # Slack uses single asterisks for bold
                pretext: subject.gsub("**", "*"),
              }

              # Change border of embed depending on state
              case state
              when :failure
                # Red
                attachment[:color] = "#e74c3c"
              when :success
                # Green
                attachment[:color] = "#2ecc71"
              end

              HTTP.post(SLACK_WEBHOOK_URL,
                json: {
                  attachments: [attachment],
                },
              )

              delivered_destinations << "Slack"
            end

            puts "#{task_identifier}: \"#{task_event_type}\" event sent to #{delivered_destinations.join(', ')}"
          end

          # Track most recent event timestamp for task so we don't re-do events we've already seen next time around
          if task_events_latest_timestamp && task_events_latest_timestamp > task_events_latest_timestamp_cached
            task_metadata[task_identifier][:latest_timestamp] = task_events_latest_timestamp
          end
        end
      end
    end
  end
end


