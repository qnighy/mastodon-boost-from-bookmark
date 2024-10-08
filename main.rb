#!/usr/bin/ruby
# frozen_string_literal: true

require "time"
require "faraday"
require "tomlrb"

class BoostFromBookmark
  def call
    if rand > threshold
      $stderr.puts "Not performing as lottery failed"
      return
    end
    $stderr.puts "Finding bookmarks..."
    bookmark = sample_bookmark
    unless bookmark
      $stderr.puts "No bookmarks found"
      return
    end

    status_url = "https://#{domain}/@#{bookmark["account"]["acct"]}/#{bookmark["id"]}"

    if retention_days
      require_older_than = Time.now - retention_days * 24 * 60 * 60
      created_at = Time.iso8601(bookmark["created_at"])
      if created_at > require_older_than
        $stderr.puts "Bookmark too new (status: #{status_url}, post created at: #{created_at})"
        return
      end
    end

    $stderr.puts "Boosting a status #{status_url}..."
    if bookmark["reblogged"]
      $stderr.puts "Already boosted"
    else
      begin
        boost_status(bookmark["id"])
      rescue Faraday::ResourceNotFound
        $stderr.puts "Post not found; removing bookmark"
        unbookmark_status(bookmark["id"])
        raise
      end
      $stderr.puts "Boosted"
    end
    unbookmark_status(bookmark["id"])
    $stderr.puts "Unbookmarked; done"
  end

  def sample_bookmark
    ratio = [0.03, 0.003, 0.001, 0.0003].sample
    bookmarks = []
    reverse_bookmark_stream.each do |bookmark|
      return bookmark if rand < ratio
      bookmarks << bookmark
    end
    bookmarks.sample
  end

  def config
    @config ||= Tomlrb.load_file("mastodon-config.toml")
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

  def domain
    config["app"]["domain"] || (raise "No domain configured")
  end

  def client_key
    config["app"]["client_key"] || (raise "No client_key configured")
  end

  def client_secret
    config["app"]["client_secret"] || (raise "No client_secret configured")
  end

  def access_token
    config["user"]["access_token"] || (raise "No access_token configured")
  end

  def threshold
    config["lottery"]["threshold"]
  end

  def retention_days
    config["lottery"]["retention_days"]
  end
end

BoostFromBookmark.new.call
