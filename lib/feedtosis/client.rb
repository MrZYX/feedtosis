module Feedtosis
  
  # Feedtosis::Client is the primary interface to the feed reader.  Call it 
  # with a url that was previously fetched while connected to the configured 
  # backend, and it will 1) only do a retrieval if deemed necessary based on the 
  # etag and modified-at of the last etag and 2) mark all entries retrieved as 
  # either new or not new.  Entries retrieved are normalized using the 
  # feed-normalizer gem.
  class Client
    attr_reader :options, :url
    
    # Some feed aggregators that we may be pulling from have entries that are present in one fetch and 
    # then disappear (Google blog search does this).  For these cases, we can't rely on only the digests of 
    # the last fetch to guarantee "newness" of a feed that we may have previously consumed.  We keep a 
    # number of previous sets of digests in order to make sure that we mark correct feeds as "new".
    RETAINED_DIGEST_SIZE = 10 unless defined?(RETAINED_DIGEST_SIZE)

    # Initializes a new feedtosis library.  The backend can be a hash of options, in 
    # which case we initialize a new HashBack::Backend.  Or, it may be a pre-initialized
    # backend, in which case we set the backend to the given HashBack::Backend object.
    def initialize(url, backend = Moneta::Memory.new)
      @url      = url
      @backend  = backend
      
      unless @backend.respond_to?(:[]) && @backend.respond_to?(:[]=)
        raise ArgumentError, "Backend needs to be a key-value store"
      end
    end
    
    # Retrieves the latest entries from this feed.  Returns a Feedtosis::Result
    # object which delegates methods to the Curl::Easy object making the request
    # and the FeedNormalizer::Feed object that may have been created from the 
    # HTTP response body.
    def fetch
      curl = build_curl_easy
      curl.perform
      feed = process_curl_response(curl)
      Feedtosis::Result.new(curl, feed)
    end
    
    private

    # Marks entries as either seen or not seen based on the unique signature of 
    # the entry, which is calculated by taking the MD5 of common attributes.
    def mark_new_entries(response)
      digests = summary_digests

      # For each entry in the responses object, mark @_seen as false if the 
      # digest of this entry doesn't exist in the cached object.
      response.entries.each do |e|
        seen = digests.include?(digest_for(e))
        e.instance_variable_set(:@_seen, seen)
      end
      
      response
    end

    # Returns an Array of summary digests for this feed.
    def summary_digests
      summary_for_feed[:digests].inject([]) do |r, e|
        r |= e
      end
    end

    # Processes the results by identifying which entries are new if the response
    # is a 200.  Otherwise, returns the Curl::Easy object for the user to inspect.
    def process_curl_response(curl)
      if curl.response_code == 200
        response = parser_for_xml(curl.body_str)
        response = mark_new_entries(response)
        store_summary_to_backend(response, curl)
        response
      end
    end
    
    # Sets options for the Curl::Easy object, including parameters for HTTP 
    # conditional GET.
    def build_curl_easy
      curl = new_curl_easy(url)

      # Many feeds have a 302 redirect to another URL.  For more recent versions 
      # of Curl, we need to specify this.
      curl.follow_location = true
      
      set_header_options(curl)
    end

    def new_curl_easy(url)
      Curl::Easy.new(url)
    end

    # Returns the summary hash for this feed from the backend store.
    def summary_for_feed
      @backend[key_for_cached] || { :digests => [ ] }
    end

    # Sets the headers from the backend, if available
    def set_header_options(curl)
      summary = summary_for_feed
      
      unless summary.nil?
        curl.headers['If-None-Match']     = summary[:etag] unless summary[:etag].nil?
        curl.headers['If-Modified-Since'] = summary[:last_modified] unless summary[:last_modified].nil?
      end
      
      curl
    end

    def key_for_cached
      MD5.hexdigest(@url)
    end
    
    # Stores information about the retrieval, including ETag, Last-Modified, 
    # and MD5 digests of all entries to the backend store.  This enables 
    # conditional GET usage on subsequent requests and marking of entries as 
    # either new or seen.
    def store_summary_to_backend(feed, curl)
      headers = HttpHeaders.new(curl.header_str)
      
      # Store info about HTTP retrieval
      summary = { }
      
      summary.merge!(:etag => headers.etag) unless headers.etag.nil?
      summary.merge!(:last_modified => headers.last_modified) unless headers.last_modified.nil?
      
      # Store digest for each feed entry so we can detect new feeds on the next 
      # retrieval
      new_digest_set = feed.entries.map do |e|
        digest_for(e)
      end
      
      new_digest_set = summary_for_feed[:digests].unshift(new_digest_set)
      new_digest_set = new_digest_set[0..RETAINED_DIGEST_SIZE]
      
      summary.merge!( :digests => new_digest_set )
      set_summary(summary)
    end
    
    def set_summary(summary)
      @backend[key_for_cached] = summary
    end
    
    # Computes a unique signature for the FeedNormalizer::Entry object given.  
    # This signature will be the MD5 of enough fields to have a reasonable 
    # probability of determining if the entry is unique or not.
    def digest_for(entry)      
      MD5.hexdigest( [ entry.title, entry.content, entry.date_published ].join )
    end
    
    def parser_for_xml(xml)
      FeedNormalizer::FeedNormalizer.parse(xml)
    end
  end
end