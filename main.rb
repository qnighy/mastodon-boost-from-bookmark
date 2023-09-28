#!/usr/bin/ruby
# frozen_string_literal: true

require "faraday"
require "tomlrb"

class BoostFromBookmark
  def call
    bookmarks = bookmark_stream.take(100)
    bookmark = bookmarks.sample
    unless bookmark["reblogged"]
      boost_status(bookmark["id"])
    end
    unbookmark_status(bookmark["id"])
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

  def bookmark_stream
    enum_for(:each_bookmarks)
  end

  def each_bookmarks
    url = "/api/v1/bookmarks"
    loop do
      resp = client.get(url)
      resp.body.each do |bookmark|
        yield bookmark
      end
      links = parse_link(resp.headers["link"])
      next_link = links.find { |link| link[:rel] == "next" }
      break if next_link.nil? || resp.body.empty?
      url = next_link[:uri]
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
end

BoostFromBookmark.new.call
