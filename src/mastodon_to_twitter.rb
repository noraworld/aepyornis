# frozen_string_literal: true

require 'bundler/setup'
# require_relative 'sample_tweets_hash.rb' if settings.development?

Bundler.require
Dotenv.load

MASTODON_API_VERSION = 'v1'
MASTODON_TIMELINE    = 'user'
MASTODON_ENDPOINT    = "wss://#{ENV['MASTODON_INSTANCE_HOST']}"        \
                       "/api/#{MASTODON_API_VERSION}/streaming"        \
                       "?access_token=#{ENV['MASTODON_ACCESS_TOKEN']}" \
                       "&stream=#{MASTODON_TIMELINE}"

def start_connection
  # https://github.com/faye/faye-websocket-ruby#initialization-options
  ws = Faye::WebSocket::Client.new(MASTODON_ENDPOINT, nil, ping: 60)

  ws.on :open do |_|
    puts 'Connection starts'
  end

  ws.on :message do |message|
    response = JSON.parse(message.data)

    if response.dig('event') == 'update'
      payload = JSON.parse(response.dig('payload'))
      pp payload
    end
  end

  ws.on :close do |_|
    puts 'Connection closed'

    # reopen the connection when closing it (reconnect when server is down and recovers)
    # https://stackoverflow.com/questions/22941084/faye-websocket-reconnect-to-socket-after-close-handler-gets-triggered
    start_connection

    puts 'Trying to reconnect...'
  end

  ws.on :error do |_|
    puts 'Unexpected error occured'
  end
end

EM.run do
  start_connection
end
