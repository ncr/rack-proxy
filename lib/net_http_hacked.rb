# frozen_string_literal: true

# DEPRECATED SHIM — scheduled for removal.
#
# rack-proxy no longer uses this monkey-patch: Rack::HttpStreamingResponse now
# streams through the public block form of Net::HTTP#request, run inside a
# Fiber (see lib/rack/http_streaming_response.rb). This file is kept for one
# release only, in case external code requires it directly and calls
# #begin_request_hacked / #end_request_hacked. It reaches into private
# net/http internals and can break on any Ruby upgrade — migrate off it.
#
# Historical context: the patch turned net/http's block-style streaming into
# return-style so the response could become a Rack body. See
# http://github.com/zerowidth/rack-streaming-proxy for an alternative that
# used an additional process.

require "net/https"

warn "[DEPRECATION] rack-proxy's net_http_hacked is deprecated and no longer used by " \
     "Rack::Proxy (streaming now uses the public Net::HTTP API). It will be removed in " \
     "a future release; stop requiring 'net_http_hacked'.", uplevel: 0

class Net::HTTP
  # Original #request with block semantics.
  #
  # def request(req, body = nil, &block)
  #   unless started?
  #     start {
  #       req['connection'] ||= 'close'
  #       return request(req, body, &block)
  #     }
  #   end
  #   if proxy_user()
  #     unless use_ssl?
  #       req.proxy_basic_auth proxy_user(), proxy_pass()
  #     end
  #   end
  #
  #   req.set_body_internal body
  #   begin_transport req
  #     req.exec @socket, @curr_http_version, edit_path(req.path)
  #     begin
  #       res = HTTPResponse.read_new(@socket)
  #     end while res.kind_of?(HTTPContinue)
  #     res.reading_body(@socket, req.response_body_permitted?) {
  #       yield res if block_given?
  #     }
  #   end_transport req, res
  #
  #   res
  # end

  def begin_request_hacked(req)
    begin_transport req
    req.exec @socket, @curr_http_version, edit_path(req.path)
    # Skip ALL 1xx interim responses (100 Continue, 103 Early Hints, etc.), not
    # just 100 Continue, to reach the final response — matching modern net/http.
    # Otherwise a backend's 103 Early Hints is mistaken for the final response.
    # standard:disable Lint/Loop -- deprecated legacy code, kept byte-faithful
    begin
      res = Net::HTTPResponse.read_new(@socket)
    end while res.is_a?(Net::HTTPInformation)
    # standard:enable Lint/Loop
    res.begin_reading_body_hacked(@socket, req.response_body_permitted?)
    @req_hacked, @res_hacked = req, res
    @res_hacked
  end

  def end_request_hacked
    @res_hacked.end_reading_body_hacked
    end_transport @req_hacked, @res_hacked
    @res_hacked
  end
end

class Net::HTTPResponse
  # Original #reading_body with block semantics
  #
  # def reading_body(sock, reqmethodallowbody)  #:nodoc: internal use only
  #   @socket = sock
  #   @body_exist = reqmethodallowbody && self.class.body_permitted?
  #   begin
  #     yield
  #     self.body   # ensure to read body
  #   ensure
  #     @socket = nil
  #   end
  # end

  def begin_reading_body_hacked(sock, reqmethodallowbody)
    @socket = sock
    @body_exist = reqmethodallowbody && self.class.body_permitted?
  end

  def end_reading_body_hacked
    body
    @socket = nil
  end
end

# Fail loudly (a warning) if this Ruby's net/http has dropped the private
# internals the shim reaches into, instead of breaking mysteriously at call
# time. Rack::Proxy itself is unaffected either way — its streaming uses the
# public Net::HTTP API (lib/rack/http_streaming_response.rb).
rack_proxy_missing_net_http = %i[begin_transport end_transport edit_path].reject do |m|
  Net::HTTP.private_method_defined?(m) || Net::HTTP.method_defined?(m)
end
rack_proxy_missing_net_http << :read_new unless Net::HTTPResponse.respond_to?(:read_new, true)
unless rack_proxy_missing_net_http.empty?
  warn "net_http_hacked: Net::HTTP internals #{rack_proxy_missing_net_http.join(", ")} are " \
       "missing on Ruby #{RUBY_VERSION}; this deprecated shim is broken here. Migrate to " \
       "Rack::Proxy's built-in streaming, which does not use these internals."
end
