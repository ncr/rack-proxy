# We are hacking net/http to change semantics of streaming handling
# from "block" semantics to regular "return" semantics.
# We need it to construct a streamable rack triplet:
#
# [status, headers, streamable_body]
#
# See http://github.com/zerowidth/rack-streaming-proxy
# for alternative that uses additional process.
#
# BTW I don't like monkey patching either
# but this is not real monkey patching.
# I just added some methods and named them very uniquely
# to avoid eventual conflicts. You're safe. Trust me.
#
# Also, in Ruby 1.9.2 you could use Fibers to avoid hacking net/http.

require 'net/https'

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
    begin
      res = Net::HTTPResponse.read_new(@socket)
    end while res.kind_of?(Net::HTTPInformation)
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
    self.body
    @socket = nil
  end
end

# Fail loudly (a warning, so non-streaming users are unaffected) if a future
# net/http drops the private internals this patch reaches into, instead of
# breaking mysteriously at request time. The planned Fiber-based rewrite (see
# MODERNIZATION_PLAN.md P1-5) removes this dependency entirely.
_rack_proxy_missing_net_http = %i[begin_transport end_transport edit_path].reject do |m|
  Net::HTTP.private_method_defined?(m) || Net::HTTP.method_defined?(m)
end
_rack_proxy_missing_net_http << :read_new unless Net::HTTPResponse.respond_to?(:read_new, true)
unless _rack_proxy_missing_net_http.empty?
  warn "net_http_hacked: Net::HTTP internals #{_rack_proxy_missing_net_http.join(', ')} are " \
       "missing on Ruby #{RUBY_VERSION}; Rack::Proxy streaming may be broken. Use streaming: false."
end
