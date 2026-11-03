#!/usr/bin/ruby
# frozen_string_literal: true

require "logger"
require "optparse"
require "time"
require "faraday"
require "tomlrb"

class BoostFromBookmark
  attr_reader :config_file, :logger

  def initialize(config_file: "mastodon-config.toml", logger: Logger.new($stderr))
    @config_file = File.expand_path(config_file)
    @logger = logger
  end

  def call
    logger.debug { "Using config file #{config_file}" }
    validate_config
    roll = rand
    if roll > threshold
      logger.info { "Not performing as lottery failed (roll: #{roll.round(4)}, threshold: #{threshold})" }
      return
    end
    logger.debug { "Lottery passed (roll: #{roll.round(4)}, threshold: #{threshold})" }
    logger.info "Finding bookmarks..."
    bookmark = sample_bookmark
    unless bookmark
      logger.info "No bookmarks found"
      return
    end

    status_url = "https://#{domain}/@#{bookmark["account"]["acct"]}/#{bookmark["id"]}"

    if retention_days
      require_older_than = Time.now - retention_days * 24 * 60 * 60
      created_at = Time.iso8601(bookmark["created_at"])
      if created_at > require_older_than
        logger.info { "Bookmark too new (status: #{status_url}, post created at: #{created_at}, retention: #{retention_days} days)" }
        return
      end
    end

    logger.info "Boosting a status #{status_url}..."
    if bookmark["reblogged"]
      logger.info "Already boosted"
    else
      begin
        boost_status(bookmark["id"])
      rescue Faraday::ResourceNotFound
        logger.warn "Post not found; removing bookmark (status: #{status_url})"
        unbookmark_status(bookmark["id"])
        raise
      end
      logger.info "Boosted"
    end
    unbookmark_status(bookmark["id"])
    logger.info "Unbookmarked; done"
  end

  def sample_bookmark
    ratio = [0.03, 0.003, 0.001, 0.0003].sample
    logger.debug { "Sampling bookmarks with ratio #{ratio}" }
    bookmarks = []
    reverse_bookmark_stream.each do |bookmark|
      if rand < ratio
        logger.debug { "Picked bookmark after scanning #{bookmarks.size + 1} bookmarks" }
        return bookmark
      end
      bookmarks << bookmark
    end
    logger.debug { "Reached the end of #{bookmarks.size} bookmarks; picking uniformly" }
    bookmarks.sample
  end

  def config
    @config ||= Tomlrb.load_file(config_file)
  end

  def boost_status(id)
    client.post("/api/v1/statuses/#{id}/reblog?id=#{id}")
  end

  def unbookmark_status(id)
    client.post("/api/v1/statuses/#{id}/unbookmark?id=#{id}")
  end

  def reverse_bookmark_stream
    enum_for(:reverse_each_bookmarks)
  end

  def reverse_each_bookmarks
    url = "/api/v1/bookmarks?min_id=0"
    loop do
      logger.debug { "Fetching #{url}" }
      resp = client.get(url)
      resp.body.reverse_each do |bookmark|
        yield bookmark
      end
      links = parse_link(resp.headers["link"])
      prev_link = links.find { |link| link[:rel] == "prev" }
      break if prev_link.nil? || resp.body.empty?
      url = prev_link[:uri]
    end
  end

  def client
    base_url = "https://#{domain}"
    token = access_token
    @client ||= Faraday.new(base_url) do |conn|
      conn.request :authorization, 'Bearer', access_token
      conn.request :url_encoded
      conn.response :json
      conn.response :raise_error
    end
  end

  def parse_link(header_value)
    return [] if header_value.nil?
    links = []
    header_value.scan(/<([^>]+)>([^,]+),?/) do |uri, link_param|
      link = { uri: uri }
      # Simplified version; should ideally parse both token=token and token=quoted-string
      link_param.scan(/(\w+)="([^"]+)"/) do |key, value|
        link[key.to_sym] = value
      end
      links << link
    end
    links
  end

  def validate_config
    domain
    client_key
    client_secret
    access_token
  end

  def domain
    config.dig("app", "domain") || (raise "No domain configured")
  end

  # Not used for now; kept so that the app credentials can be stored alongside.
  def client_key
    secret("app", "client_key", required: false)
  end

  # Not used for now; kept so that the app credentials can be stored alongside.
  def client_secret
    secret("app", "client_secret", required: false)
  end

  def access_token
    secret("user", "access_token")
  end

  # Reads a secret either from the config file or from the environment
  # variable MASTODON_<KEY>, but not both. Empty values are treated as unset.
  def secret(section, key, required: true)
    env_name = "MASTODON_#{key.upcase}"
    config_value = config.dig(section, key)
    config_value = nil if config_value == ""
    env_value = ENV[env_name]
    env_value = nil if env_value == ""
    if config_value && env_value
      raise "#{key} is configured both in #{config_file} and in #{env_name}; use only one"
    end
    value = config_value || env_value
    if required && !value
      raise "No #{key} configured (set #{section}.#{key} in #{config_file} or #{env_name})"
    end
    value
  end

  def threshold
    config.dig("lottery", "threshold")
  end

  def retention_days
    config.dig("lottery", "retention_days")
  end
end

logger = Logger.new($stderr, level: ENV.fetch("LOG_LEVEL", "info"))
options = { logger: }
OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options]"
  opts.on("-c", "--config FILE", "Config file (default: ./mastodon-config.toml)") do |v|
    options[:config_file] = v
  end
  opts.on("-v", "--verbose", "Enable debug logging (or set LOG_LEVEL=debug)") do
    logger.level = Logger::DEBUG
  end
end.parse!

begin
  BoostFromBookmark.new(**options).call
rescue Faraday::Error => e
  request = e.response&.dig(:request)
  request_info = " (#{request[:method].to_s.upcase} #{request[:url]})" if request
  logger.error { "#{e.class}: #{e.message}#{request_info}" }
  logger.debug { e.full_message(highlight: false) }
  exit 1
rescue StandardError => e
  logger.error { "#{e.class}: #{e.message}" }
  logger.debug { e.full_message(highlight: false) }
  exit 1
end
