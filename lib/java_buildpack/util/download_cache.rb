# Encoding: utf-8
# Cloud Foundry Java Buildpack
# Copyright 2013 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'java_buildpack/diagnostics'
require 'java_buildpack/diagnostics/logger_factory'
require 'java_buildpack/util'
require 'java_buildpack/util/file_cache'
require 'monitor'
require 'net/http'
require 'tmpdir'
require 'uri'
require 'yaml'

module JavaBuildpack::Util

  # A cache for downloaded files that is configured to use a filesystem as the backing store. This cache uses standard
  # file locking (<tt>File.flock()</tt>) in order ensure that mutation of files in the cache is non-concurrent across
  # processes.  Reading files (once they've been downloaded) happens concurrently so read performance is not impacted.
  class DownloadCache # rubocop:disable ClassLength

    # Creates an instance of the cache that is backed by the filesystem rooted at +cache_root+
    #
    # @param [String] cache_root the filesystem root for downloaded files to be cached in
    def initialize(cache_root = Dir.tmpdir)
      @cache_root = cache_root
      @logger = JavaBuildpack::Diagnostics::LoggerFactory.get_logger
    end

    # Retrieves an item from the cache.  Retrieval of the item uses the following algorithm:
    #
    # 1. Obtain an exclusive lock based on the URI of the item. This allows concurrency for different items, but not for
    #    the same item.
    # 2. If the the cached item does not exist, download from +uri+ and cache it, its +Etag+, and its +Last-Modified+
    #    values if they exist.
    # 3. If the cached file does exist, and the original download had an +Etag+ or a +Last-Modified+ value, attempt to
    #    download from +uri+ again.  If the result is +304+ (+Not-Modified+), then proceed without changing the cached
    #    item.  If it is anything else, overwrite the cached file and its +Etag+ and +Last-Modified+ values if they exist.
    # 4. Downgrade the lock to a shared lock as no further mutation of the cache is possible.  This allows concurrency for
    #    read access of the item.
    # 5. Yield the cached file (opened read-only) to the passed in block. Once the block is complete, the file is closed
    #    and the lock is released.
    #
    # @param [String] uri the uri to download if the item is not already in the cache.  Also used in the case where the
    #                     item is already in the cache, to validate that the item is up to date
    # @yieldparam [File] file the file representing the cached item. In order to ensure that the file is not changed or
    #                    deleted while it is being used, the cached item can only be accessed as part of a block.
    # @return [void]
    def get(uri)
      file_cache = FileCache.new(@cache_root, uri)

      file_cache.lock do |locked_file_cache|
        internet_up, file_downloaded = DownloadCache.internet_available?(locked_file_cache, uri, @logger)

        unless file_downloaded
          if internet_up && locked_file_cache.should_update
            update(locked_file_cache, uri)
          elsif locked_file_cache.should_download
            download(locked_file_cache, uri, internet_up)
          end
        end
      end

      file_cache.data do |file_data|
        yield file_data
      end
    end

    # Remove an item from the cache
    #
    # @param [String] uri the URI of the item to remove
    # @return [void]
    def evict(uri)
      FileCache.new(@cache_root, uri).destroy
    end

    private

    CACHE_CONFIG = '../../../config/cache.yml'.freeze

    HTTP_ERRORS = [
        EOFError,
        Errno::ECONNABORTED,
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        Errno::EHOSTDOWN,
        Errno::EHOSTUNREACH,
        Errno::EINVAL,
        Errno::ENETDOWN,
        Errno::ENETRESET,
        Errno::ENETUNREACH,
        Errno::ENONET,
        Errno::ENOTCONN,
        Errno::EPIPE,
        Errno::ETIMEDOUT,
        Net::HTTPBadResponse,
        Net::HTTPHeaderSyntaxError,
        Net::ProtocolError,
        SocketError,
        Timeout::Error
    ].freeze

    HTTP_OK = '200'.freeze

    TIMEOUT_SECONDS = 10

    INTERNET_DETECTION_RETRY_LIMIT = 5

    DOWNLOAD_RETRY_LIMIT = 5

    @@monitor = Monitor.new
    @@internet_checked = false
    @@internet_up = true

    def self.get_configuration
      expanded_path = File.expand_path(CACHE_CONFIG, File.dirname(__FILE__))
      YAML.load_file(expanded_path)
    end

    def self.internet_available?(file_cache, uri, logger)
      @@monitor.synchronize do
        return @@internet_up, false if @@internet_checked # rubocop:disable RedundantReturn
      end
      cache_configuration = get_configuration
      if cache_configuration['remote_downloads'] == 'disabled'
        return store_internet_availability(false), false # rubocop:disable RedundantReturn
      elsif cache_configuration['remote_downloads'] == 'enabled'
        begin
          # Beware known problems with timeouts: https://www.ruby-forum.com/topic/143840
          opts = { read_timeout: TIMEOUT_SECONDS, connect_timeout: TIMEOUT_SECONDS, open_timeout: TIMEOUT_SECONDS }
          return http_get(uri, INTERNET_DETECTION_RETRY_LIMIT, logger, opts) do |response|
            internet_up = response.code == HTTP_OK
            write_response(file_cache, response) if internet_up
            return store_internet_availability(internet_up), internet_up # rubocop:disable RedundantReturn
          end
        rescue *HTTP_ERRORS => ex
          logger.debug { "Internet detection failed with #{ex}" }
          return store_internet_availability(false), false # rubocop:disable RedundantReturn
        end
      else
        fail "Invalid remote_downloads property in cache configuration: #{cache_configuration}"
      end
    end

    def self.http_get(uri, retry_limit, logger, opts = {}, &block)
      rich_uri = URI(uri)
      options = opts.merge(use_ssl: DownloadCache.use_ssl?(rich_uri))
      Net::HTTP.start(rich_uri.host, rich_uri.port, options) do |http|
        request = Net::HTTP::Get.new(uri)
        return retry_http_request(http, request, retry_limit, logger, &block)
      end
    end

    def self.retry_http_request(http, request, retry_limit, logger)
      1.upto(retry_limit) do |try|
        begin
          http.request request do |response|
            if response.code == HTTP_OK || try == retry_limit
              return yield response
            end
          end
        rescue *HTTP_ERRORS => ex
          logger.debug { "HTTP get attempt #{try} of #{retry_limit} failed: #{ex}" }
          raise ex if try == retry_limit
        end
      end
    end

    def self.store_internet_availability(internet_up)
      @@monitor.synchronize do
        @@internet_up = internet_up
        @@internet_checked = true
      end
      internet_up
    end

    def self.clear_internet_availability
      @@monitor.synchronize do
        @@internet_checked = false
      end
    end

    def download(file_cache, uri, internet_up)
      if internet_up
        begin
          DownloadCache.http_get(uri, DOWNLOAD_RETRY_LIMIT, @logger) do |response|
            DownloadCache.write_response(file_cache, response)
          end
        rescue *HTTP_ERRORS => ex
          puts 'FAIL'
          error_message = "Unable to download from #{uri} due to #{ex}"
          raise error_message
        end
      else
        look_aside(file_cache, uri)
      end
    end

    # A download has failed, so check the read-only buildpack cache for the file
    # and use the copy there if it exists.
    def look_aside(file_cache, uri)
      @logger.debug "Unable to download from #{uri}. Looking in buildpack cache."
      key = URI.escape(uri, '/')
      stashed = File.join(ENV['BUILDPACK_CACHE'], 'java-buildpack', "#{key}.cached")
      @logger.debug { "Looking in buildpack cache for file '#{stashed}'" }
      if File.exist? stashed
        file_cache.persist_file stashed
        @logger.debug "Using copy of #{uri} from buildpack cache."
      else
        message = "Buildpack cache does not contain #{uri}. Failing the download."
        @logger.error message
        @logger.debug { "Buildpack cache contents:\n#{`ls -lR #{File.join(ENV['BUILDPACK_CACHE'], 'java-buildpack')}`}" }
        fail message
      end
    end

    def update(file_cache, uri)
      rich_uri = URI(uri)

      Net::HTTP.start(rich_uri.host, rich_uri.port, use_ssl: DownloadCache.use_ssl?(rich_uri)) do |http|
        request = Net::HTTP::Get.new(uri)

        file_cache.etag do |etag_content|
          request['If-None-Match'] = etag_content
        end

        file_cache.last_modified do |last_modified_content|
          request['If-Modified-Since'] = last_modified_content
        end

        http.request request do |response|
          DownloadCache.write_response(file_cache, response) unless response.code == '304'
        end
      end

    rescue *HTTP_ERRORS => ex
      @logger.warn "Unable to update from #{uri} due to #{ex}. Using cached version."
    end

    def self.use_ssl?(uri)
      uri.scheme == 'https'
    end

    def self.write_response(file_cache, response)
      file_cache.persist_etag response['Etag']
      file_cache.persist_last_modified response['Last-Modified']

      file_cache.persist_data do |cached_file|
        response.read_body do |chunk|
          cached_file.write(chunk)
        end
      end
    end

  end

end
