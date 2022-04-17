# frozen_string_literal: true

require 'bundler/setup'
require 'faraday'
require 'logger'
require 'open-uri'
require 'sinatra'
require 'sinatra/reloader' if settings.development?
require_relative 'sample_tweets_hash.rb' if settings.development?

Bundler.require
Dotenv.load

logger = Logger.new('logs/debug.log', 'monthly')

post '/' do
  params = settings.production? ? JSON.parse(request.body.read) : mock_params
  logger.debug(params)

  return if ignore?(params)

  conn = Faraday.new(
    url: "https://#{ENV['MASTODON_INSTANCE_HOST']}",
    headers: { 'Authorization' => "Bearer #{ENV['MASTODON_ACCESS_TOKEN']}" }
  ) do |builder|
    builder.request :multipart
    builder.request :url_encoded
    builder.adapter :net_http
  end

  twimgs = (params.dig(0, 'extended_tweet', 'extended_entities', 'media') || params.dig(0, 'extended_entities', 'media'))&.map do |medium|
    ext = File.extname(medium['media_url_https'])
    "#{medium['media_url_https'].chomp(ext)}?format=#{ext.delete('.')}&name=large"
  end

  media_ids = twimgs&.map&.with_index do |path, index|
    # https://stackoverflow.com/questions/56392828/path-name-contains-null-byte-for-image-url-while-existing
    t = Tempfile.new
    logger.debug("(#{index + 1}/#{twimgs.count}) Download image from Twitter...")
    t.write(open(path).read)
    logger.debug("(#{index + 1}/#{twimgs.count}) Download complete!")
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
  logger.debug("Tooted successfully!!!\n\n")
end

def ignore?(params)
  if params[0]['in_reply_to_user_id_str'] != params[0]['user']['id_str'] && /^@/ =~ params[0]['text']
    logger.debug('TWEET SKIPPED. Reason: reply to someone!')
    logger.debug(params[0]['in_reply_to_user_id_str'])
    logger.debug(params[0]['user']['id_str'])
    logger.debug(params[0]['text'])

    return true
  end

  if params.dig(0, 'source').include?(ENV['TWITTER_APP_NAME_TO_TWEET_MASTODON_STATUSES'])
    logger.debug("TWEET SKIPPED. Reason: tweet from #{ENV['TWITTER_APP_NAME_TO_TWEET_MASTODON_STATUSES']}!")
    logger.debug(params.dig(0, 'source'))
    logger.debug(ENV['TWITTER_APP_NAME_TO_TWEET_MASTODON_STATUSES'])

    return true
  end

  false
end

def pretty_text(params)
  # loooooooooooooooooooong tw ... => loooooooooooooooooooong tweeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeet!
  # or, normal tweet!
  text = params.dig(0, 'extended_tweet', 'full_text') || params.dig(0, 'text')

  # https://t.co/foo => https://www.example.com
  (params.dig(0, 'extended_tweet', 'entities', 'urls') || params.dig(0, 'entities', 'urls'))&.each do |url|
    text.gsub!(url['url'], url['expanded_url'])
  end

  # Retweet without my comment: replace text with retweeted tweet URL only
  if params.dig(0, 'retweeted_status', 'user', 'id_str') && params.dig(0, 'retweeted_status', 'user', 'id_str') != params.dig(0, 'user', 'id_str')
    text = "https://twitter.com/i/web/status/#{params.dig(0, 'retweeted_status', 'id_str')}"

    # MEMO: This does not work properly because retweeted tweet URL does not become to be contained when my comment contains other URL
    # text = params.dig(0, 'retweeted_status', 'entities', 'urls', 0, 'expanded_url')
  end

  # Retweet with my comment: my comment + retweeted tweet URL
  if params.dig(0, 'quoted_status_permalink')
    text = "#{text}\n\nhttps://twitter.com/i/web/status/#{params.dig(0, 'quoted_status', 'id_str')}"

    # MEMO: This does not work properly because retweeted tweet URL does not become to be contained when my comment contains other URL
    # text = "#{text}\n\n#{params.dig(0, 'quoted_status', 'entities', 'urls', 0, 'expanded_url')}"
  end

  # trim image shorten URL (https://t.co/foo as image URL)
  text.gsub(%r{https://t.co/[a-zA-Z0-9]+}, '')
end
