module HH::API
  # The Home tab checks for a connection while the app is booting, so a slow
  # DNS lookup or an unresponsive server must fail fast rather than hold the
  # window hostage -- Net::HTTP's default timeouts are a full minute each.
  OPEN_TIMEOUT = 3
  READ_TIMEOUT = 5

  @root = nil
  @refresh_time = nil

  class << self
    def root
      if !@refresh_time || (Time.now.to_i - @refresh_time.to_i) > 3600
        @refresh_time = Time.now
        @root = get('/') { |f| Hpricot(f.body) }
      else
        @root
      end
    end

    def get(path)
      url = URI.parse(HH::API_ROOT + path)
      response = start(url) { |http| http.request_get(url.request_uri) }

      yield response
    end

    def post(path, params)
      url = URI.parse(HH::API_ROOT + path)
      response = start(url) { |http| http.post(url.request_uri, URI.encode_www_form(params)) }

      yield response
    end

    private

    def start(url, &blk)
      Net::HTTP.start(url.host, url.port,
        :use_ssl => url.scheme == "https",
        :open_timeout => OPEN_TIMEOUT, :read_timeout => READ_TIMEOUT, &blk)
    end
  end

end
