# frozen_string_literal: true

require 'bundler/setup'
require 'faraday'
require 'open-uri'
require 'sinatra'
require 'sinatra/reloader' if settings.development?
require_relative 'sample_tweets_hash.rb' if settings.development?

Bundler.require
Dotenv.load

post '/' do
  params = settings.production? ? JSON.parse(request.body.read) : mock_params

  return if ignore?(params)

  conn = Faraday.new(
    url: "https://#{ENV['MASTODON_INSTANCE_HOST']}",
    headers: { 'Authorization' => "Bearer #{ENV['MASTODON_ACCESS_TOKEN']}" }
  ) do |builder|
    builder.request :multipart
    builder.request :url_encoded
    builder.adapter :net_http
  end

  twimgs = params.dig(0, 'extended_entities', 'media')&.map do |medium|
    ext = File.extname(medium['media_url_https'])
    "#{medium['media_url_https'].chomp(ext)}?format=#{ext.delete('.')}&name=large"
  end

  media_ids = twimgs&.map&.with_index do |path, index|
    # https://stackoverflow.com/questions/56392828/path-name-contains-null-byte-for-image-url-while-existing
    t = Tempfile.new
    puts "(#{index + 1}/#{twimgs.count}) Download image from Twitter..."
    t.write(open(path).read)
    puts "(#{index + 1}/#{twimgs.count}) Download complete!"
    t.close

    payload = {
      file: Faraday::UploadIO.new(t.path, 'image/jpeg', 'image.jpg')
    }

    res = conn.post '/api/v1/media', payload

    t.unlink

    JSON.parse(res.body)['id'].to_i
  end

  payload = {
    status: pretty_text(params),
    media_ids: media_ids ? media_ids : nil,
    visibility: settings.production? ? 'public' : 'direct'
  }

  conn.post '/api/v1/statuses', payload
  puts "Tooted successfully!!!\n\n"
end

def ignore?(params)
  if params[0]['in_reply_to_user_id_str'] != params[0]['user']['id_str'] && /^@/ =~ params[0]['text']
    puts 'TWEET SKIPPED. Reason: reply to someone!'
    pp params[0]['in_reply_to_user_id_str']
    pp params[0]['user']['id_str']
    pp params[0]['text']

    return true
  end

  if params.dig(0, 'retweeted_status', 'user', 'id_str') && params.dig(0, 'retweeted_status', 'user', 'id_str') != params.dig(0, 'user', 'id_str')
    puts 'TWEET SKIPPED. Reason: retweet!'
    pp params.dig(0, 'retweeted_status', 'user', 'id_str')
    pp params.dig(0, 'user', 'id_str')

    return true
  end

  if params.dig(0, 'source').include?(ENV['TWITTER_APP_NAME_TO_TWEET_MASTODON_STATUSES'])
    puts 'TWEET SKIPPED. Reason: tweet from Aepyornis!'
    pp params.dig(0, 'source')
    pp ENV['TWITTER_APP_NAME_TO_TWEET_MASTODON_STATUSES']

    return true
  end

  false
end

def pretty_text(params)
  # loooooooooooooooooooong tw ... => loooooooooooooooooooong tweet!
  # or, normal tweet!
  text = params.dig(0, 'extended_tweet', 'full_text') || params.dig(0, 'text')

  # https://t.co/foo => https://www.example.com
  params.dig(0, 'entities', 'urls')&.each do |url|
    text.gsub!(url['url'], url['expanded_url'])
  end

  if params.dig(0, 'quoted_status_permalink')
    text = "#{text}\n\n#{params.dig(0, 'quoted_status_permalink', 'expanded')}"
  end

  # trim image shorten URL (https://t.co/foo as image URL)
  text.gsub(%r{https://t.co/[a-zA-Z0-9]+}, '')
end
