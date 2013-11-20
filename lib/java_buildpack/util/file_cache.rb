# Encoding: utf-8
# Cloud Foundry Java Buildpack
# Copyright (c) 2013 the original author or authors.
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

require 'fileutils'
require 'java_buildpack/util'

module JavaBuildpack::Util

  # A cache for a single file which uses a filesystem as the backing store. This cache uses standard
  # file locking (<tt>File.flock()</tt>) in order ensure that mutation of files in the cache is non-concurrent across
  # processes.  Reading files happens concurrently so read performance is not impacted.
  class FileCache

    # Creates an instance of the file cache that is backed by the filesystem rooted at +cache_root+
    #
    # @param [String] cache_root the filesystem root for the file to be cached in
    # @param [String] uri a uri which uniquely identifies the file in the cache root
    def initialize(cache_root, uri)
      FileUtils.mkdir_p(cache_root)
      @cache_root = cache_root

      key = URI.escape(uri, '/')
      @lock = File.join(@cache_root, "#{key}.lock")
      cached = File.join(@cache_root, "#{key}.cached")
      etag = File.join(@cache_root, "#{key}.etag")
      last_modified = File.join(@cache_root, "#{key}.last_modified")

      File.open(@lock, File::CREAT) do |lock_file|
        lock_file.flock(File::LOCK_EX)
        @locked_file_cache = LockedFileCache.new(cached, etag, last_modified)
        lock_file.flock(File::LOCK_SH)
      end

    end

    # Perform an operation with the file cache locked.
    # TODO @yieldparam [File] file the file representing the cached item. In order to ensure that the file is not changed or
    # TODO                   deleted while it is being used, the cached item can only be accessed as part of a block.
    def lock
      File.open(@lock, File::CREAT) do |lock_file|
        lock_file.flock(File::LOCK_EX)
        yield @locked_file_cache
        lock_file.flock(File::LOCK_SH)
      end
    end

    def data(&block)
      @locked_file_cache.data(&block)
    end

    def destroy
      lock do |locked_file_cache|
        locked_file_cache.destroy
      end
      LockedFileCache.delete_file @lock
    end

    class LockedFileCache
      def initialize(cached, etag, last_modified)
        @cached = cached
        @etag = etag
        @last_modified = last_modified
      end

      def persist_etag(etag_data)
        persist(etag_data, @etag)
      end

      def persist_last_modified(last_modified_data)
        persist(last_modified_data, @last_modified)
      end

      def persist_data
        File.open(@cached, File::CREAT | File::WRONLY) do |cached_file|
          yield cached_file
        end
      end

      def persist_file(file)
        FileUtils.cp(file, @cached)
      end

      def should_update
        File.exists?(@cached) && (File.exists?(@etag) || File.exists?(@last_modified))
      end

      def should_download
        !File.exists? @cached
      end

      def etag(&block)
        yield_file_data(@etag, &block)
      end

      def last_modified(&block)
        yield_file_data(@last_modified, &block)
      end

      # This operation may be called without the caller holding the lock.
      def data
        File.open(@cached, File::RDONLY) do |cached_file|
          yield cached_file
        end
      end

      def destroy
        LockedFileCache.delete_file @cached
        LockedFileCache.delete_file @etag
        LockedFileCache.delete_file @last_modified
      end

      private

      def persist data, file
        unless data.nil?
          File.open(file, File::CREAT | File::WRONLY) do |open_file|
            open_file.write(data)
            open_file.fsync
          end
        end
      end

      def yield_file_data(file)
        if File.exists?(file)
          File.open(file, File::RDONLY) do |open_file|
            yield open_file.read
          end
        end
      end

      def self.delete_file(filename)
        File.delete filename if File.exists? filename
      end

    end

  end

end
