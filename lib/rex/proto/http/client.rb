# -*- coding: binary -*-

require 'rex/socket'

require 'rex/text'
require 'digest'

module Rex
  module Proto
    module Http
      ###
      #
      # Acts as a client to an HTTP server, sending requests and receiving responses.
      #
      # See the RFC: http://www.w3.org/Protocols/rfc2616/rfc2616.html
      #
      ###
      class Client

        #
        # Creates a new client instance
        #
        # @param [Rex::Proto::Http::HttpSubscriber] subscriber A subscriber to Http requests/responses
        def initialize(host, port = 80, context = {}, ssl = nil, ssl_version = nil, proxies = nil, username = '', password = '', kerberos_authenticator: nil, comm: nil, subscriber: nil, sslkeylogfile: nil)
          self.hostname = host
          self.port = port.to_i
          self.context = context
          self.ssl = ssl
          self.ssl_version = ssl_version
          self.proxies = proxies
          self.username = username
          self.password = password
          self.kerberos_authenticator = kerberos_authenticator
          self.comm = comm
          self.subscriber = subscriber || HttpSubscriber.new
          self.sslkeylogfile = sslkeylogfile

          # Take ClientRequest's defaults, but override with our own
          self.config = Http::ClientRequest::DefaultConfig.merge({
            'read_max_data' => (1024 * 1024 * 1),
            'vhost' => hostname,
            'ssl_server_name_indication' => hostname
          })
          config['agent'] ||= Rex::UserAgent.session_agent

          # XXX: This info should all be controlled by ClientRequest
          self.config_types = {
            'uri_encode_mode' => ['hex-normal', 'hex-all', 'hex-random', 'hex-noslashes', 'u-normal', 'u-random', 'u-all'],
            'uri_encode_count' => 'integer',
            'uri_full_url' => 'bool',
            'pad_method_uri_count' => 'integer',
            'pad_uri_version_count' => 'integer',
            'pad_method_uri_type' => ['space', 'tab', 'apache'],
            'pad_uri_version_type' => ['space', 'tab', 'apache'],
            'method_random_valid' => 'bool',
            'method_random_invalid' => 'bool',
            'method_random_case' => 'bool',
            'version_random_valid' => 'bool',
            'version_random_invalid' => 'bool',
            'uri_dir_self_reference' => 'bool',
            'uri_dir_fake_relative' => 'bool',
            'uri_use_backslashes' => 'bool',
            'pad_fake_headers' => 'bool',
            'pad_fake_headers_count' => 'integer',
            'pad_get_params' => 'bool',
            'pad_get_params_count' => 'integer',
            'pad_post_params' => 'bool',
            'pad_post_params_count' => 'integer',
            'shuffle_get_params' => 'bool',
            'shuffle_post_params' => 'bool',
            'uri_fake_end' => 'bool',
            'uri_fake_params_start' => 'bool',
            'header_folding' => 'bool',
            'chunked_size' => 'integer',
            'partial' => 'bool'
          }
        end

        #
        # Set configuration options
        #
        def set_config(opts = {})
          opts.each_pair do |var, val|
            # Default type is string
            typ = config_types[var] || 'string'

            # These are enum types
            if typ.is_a?(Array) && !typ.include?(val)
              raise "The specified value for #{var} is not one of the valid choices"
            end

            # The caller should have converted these to proper ruby types, but
            # take care of the case where they didn't before setting the
            # config.

            if (typ == 'bool')
              val = val == true || val.to_s =~ /^(t|y|1)/i
            end

            if (typ == 'integer')
              val = val.to_i
            end

            config[var] = val
          end
        end

        #
        # Create an arbitrary HTTP request
        #
        # @param opts [Hash]
        # @option opts 'agent'         [String] User-Agent header value
        # @option opts 'connection'    [String] Connection header value
        # @option opts 'cookie'        [String] Cookie header value
        # @option opts 'data'          [String] HTTP data (only useful with some methods, see rfc2616)
        # @option opts 'encode'        [Bool]   URI encode the supplied URI, default: false
        # @option opts 'headers'       [Hash]   HTTP headers, e.g. <code>{ "X-MyHeader" => "value" }</code>
        # @option opts 'method'        [String] HTTP method to use in the request, not limited to standard methods defined by rfc2616, default: GET
        # @option opts 'proto'         [String] protocol, default: HTTP
        # @option opts 'query'         [String] raw query string
        # @option opts 'raw_headers'   [String] Raw HTTP headers
        # @option opts 'uri'           [String] the URI to request
        # @option opts 'version'       [String] version of the protocol, default: 1.1
        # @option opts 'vhost'         [String] Host header value
        #
        # @return [ClientRequest]
        def request_raw(opts = {})
          opts = config.merge(opts)

          opts['cgi'] = false
          opts['port'] = port
          opts['ssl'] = ssl

          ClientRequest.new(opts)
        end

        #
        # Create a CGI compatible request
        #
        # @param (see #request_raw)
        # @option opts (see #request_raw)
        # @option opts 'ctype'         [String] Content-Type header value, default for POST requests: +application/x-www-form-urlencoded+
        # @option opts 'encode_params' [Bool]   URI encode the GET or POST variables (names and values), default: true
        # @option opts 'vars_get'      [Hash]   GET variables as a hash to be translated into a query string
        # @option opts 'vars_post'     [Hash]   POST variables as a hash to be translated into POST data
        # @option opts 'vars_form_data'     [Hash]   POST form_data variables as a hash to be translated into multi-part POST form data
        #
        # @return [ClientRequest]
        def request_cgi(opts = {})
          opts = config.merge(opts)

          opts['cgi'] = true
          opts['port'] = port
          opts['ssl'] = ssl

          ClientRequest.new(opts)
        end

        #
        # Connects to the remote server if possible.
        #
        # @param t [Integer] Timeout
        # @see Rex::Socket::Tcp.create
        # @return [Rex::Socket::Tcp]
        def connect(t = -1)
          # If we already have a connection and we aren't pipelining, close it.
          if conn
            if !pipelining?
              close
            else
              return conn
            end
          end

          timeout = (t.nil? or t == -1) ? 0 : t

          self.conn = Rex::Socket::Tcp.create(
            'PeerHost' => hostname,
            'PeerHostname' => config['ssl_server_name_indication'] || config['vhost'],
            'PeerPort' => port.to_i,
            'LocalHost' => local_host,
            'LocalPort' => local_port,
            'Context' => context,
            'SSL' => ssl,
            'SSLVersion' => ssl_version,
            'SSLKeyLogFile' => sslkeylogfile,
            'Proxies' => proxies,
            'Timeout' => timeout,
            'Comm' => comm
          )
        end

        #
        # Closes the connection to the remote server.
        #
        def close
          if conn && !conn.closed?
            conn.shutdown
            conn.close
          end

          self.conn = nil
          self.ntlm_client = nil
        end

        #
        # Sends a request and gets a response back
        #
        # If the request is a 401, and we have creds, it will attempt to complete
        # authentication and return the final response
        #
        # @return (see #_send_recv)
        def send_recv(req, t = -1, persist = false)
          res = _send_recv(req, t, persist)
          if res and res.code == 401 and res.headers['WWW-Authenticate']
            res = send_auth(res, req.opts, t, persist)
          end
          res
        end

        #
        # Transmit an HTTP request and receive the response
        #
        # If persist is set, then the request will attempt to reuse an existing
        # connection.
        #
        # Call this directly instead of {#send_recv} if you don't want automatic
        # authentication handling.
        #
        # @return (see #read_response)
        def _send_recv(req, t = -1, persist = false)
          @pipeline = persist
          subscriber.on_request(req)
          if req.respond_to?(:opts) && req.opts['ntlm_transform_request'] && ntlm_client
            req = req.opts['ntlm_transform_request'].call(ntlm_client, req)
          elsif req.respond_to?(:opts) && req.opts['krb_transform_request'] && krb_encryptor
            req = req.opts['krb_transform_request'].call(krb_encryptor, req)
          end

          send_request(req, t)

          res = read_response(t, original_request: req)
          if req.respond_to?(:opts) && req.opts['ntlm_transform_response'] && ntlm_client
            req.opts['ntlm_transform_response'].call(ntlm_client, res)
          elsif req.respond_to?(:opts) && req.opts['krb_transform_response'] && krb_encryptor
            req = req.opts['krb_transform_response'].call(krb_encryptor, res)
          end
          res.request = req.to_s if res
          res.peerinfo = peerinfo if res
          subscriber.on_response(res)
          res
        end

        #
        # Send an HTTP request to the server
        #
        # @param req [Request,ClientRequest,#to_s] The request to send
        # @param t (see #connect)
        #
        # @return [void]
        def send_request(req, t = -1)
          connect(t)
          conn.put(req.to_s)
        end

        # Resends an HTTP Request with the proper authentication headers
        # set. If we do not support the authentication type the server requires
        # we return the original response object
        #
        # @param res [Response] the HTTP Response object
        # @param opts [Hash] the options used to generate the original HTTP request
        # @param t [Integer] the timeout for the request in seconds
        # @param persist [Boolean] whether or not to persist the TCP connection (pipelining)
        #
        # @return [Response] the last valid HTTP response object we received
        def send_auth(res, opts, t, persist)
          if opts['username'].nil? or opts['username'] == ''
            if username and !(username == '')
              opts['username'] = username
              opts['password'] = password
            else
              opts['username'] = nil
              opts['password'] = nil
            end
          end

          if opts[:kerberos_authenticator].nil?
            opts[:kerberos_authenticator] = kerberos_authenticator
          end

          return res if (opts['username'].nil? or opts['username'] == '') and opts[:kerberos_authenticator].nil?

          supported_auths = res.headers['WWW-Authenticate']

          # if several providers are available, the client may want one in particular
          preferred_auth = opts['preferred_auth']

          if supported_auths.include?('Basic') && (preferred_auth.nil? || preferred_auth == 'Basic')
            opts['headers'] ||= {}
            opts['headers']['Authorization'] = basic_auth_header(opts['username'], opts['password'])
            req = request_cgi(opts)
            res = _send_recv(req, t, persist)
            return res
          elsif supported_auths.include?('Digest') && (preferred_auth.nil? || preferred_auth == 'Digest')
            temp_response = digest_auth(opts)
            if temp_response.is_a? Rex::Proto::Http::Response
              res = temp_response
            end
            return res
          elsif supported_auths.include?('NTLM') && (preferred_auth.nil? || preferred_auth == 'NTLM')
            opts['provider'] = 'NTLM'
            temp_response = negotiate_auth(opts)
            if temp_response.is_a? Rex::Proto::Http::Response
              res = temp_response
            end
            return res
          elsif supported_auths.include?('Negotiate') && (preferred_auth.nil? || preferred_auth == 'Negotiate')
            opts['provider'] = 'Negotiate'
            temp_response = negotiate_auth(opts)
            if temp_response.is_a? Rex::Proto::Http::Response
              res = temp_response
            end
            return res
          elsif supported_auths.include?('Negotiate') && (preferred_auth.nil? || preferred_auth == 'Kerberos')
            opts['provider'] = 'Negotiate'
            temp_response = kerberos_auth(opts)
            if temp_response.is_a? Rex::Proto::Http::Response
              res = temp_response
            end
            return res
          end
          return res
        end

        # Converts username and password into the HTTP Basic authorization
        # string.
        #
        # @return [String] A value suitable for use as an Authorization header
        def basic_auth_header(username, password)
          auth_str = username.to_s + ':' + password.to_s
          'Basic ' + Rex::Text.encode_base64(auth_str)
        end
        # Send a series of requests to complete Digest Authentication
        #
        # @param opts [Hash] the options used to build an HTTP request
        # @return [Response] the last valid HTTP response we received
        def digest_auth(opts = {})
          to = opts['timeout'] || 20

          digest_user = opts['username'] || ''
          digest_password = opts['password'] || ''

          method = opts['method']
          path = opts['uri']
          iis = true
          if (opts['DigestAuthIIS'] == false or config['DigestAuthIIS'] == false)
            iis = false
          end

          begin
            resp = opts['response']

            if !resp
              # Get authentication-challenge from server, and read out parameters required
              r = request_cgi(opts.merge({
                'uri' => path,
                'method' => method
              }))
              resp = _send_recv(r, to)
              unless resp.is_a? Rex::Proto::Http::Response
                return nil
              end

              if resp.code != 401
                return resp
              end
              return resp unless resp.headers['WWW-Authenticate']
            end

            # Don't anchor this regex to the beginning of string because header
            # folding makes it appear later when the server presents multiple
            # WWW-Authentication options (such as is the case with IIS configured
            # for Digest or NTLM).
            resp['www-authenticate'] =~ /Digest (.*)/

            parameters = {}
            ::Regexp.last_match(1).split(/,[[:space:]]*/).each do |p|
              k, v = p.split('=', 2)
              parameters[k] = v.gsub('"', '')
            end

            auth_digest = Rex::Proto::Http::AuthDigest.new
            auth = auth_digest.digest(digest_user, digest_password, method, path, parameters, iis)

            headers = { 'Authorization' => auth.join(', ') }
            headers.merge!(opts['headers']) if opts['headers']

            # Send main request with authentication
            r = request_cgi(opts.merge({
              'uri' => path,
              'method' => method,
              'headers' => headers
            }))
            resp = _send_recv(r, to, true)
            unless resp.is_a? Rex::Proto::Http::Response
              return nil
            end

            return resp
          rescue ::Errno::EPIPE, ::Timeout::Error
          end
        end

        def kerberos_auth(opts = {})
          to = opts['timeout'] || 20
          auth_result = kerberos_authenticator.authenticate(mechanism: Rex::Proto::Gss::Mechanism::KERBEROS)
          gss_data = auth_result[:security_blob]
          gss_data_b64 = Rex::Text.encode_base64(gss_data)

          # Separate options for the auth requests
          auth_opts = opts.clone
          auth_opts['headers'] = opts['headers'].clone
          auth_opts['headers']['Authorization'] = "Kerberos #{gss_data_b64}"

          if auth_opts['no_body_for_auth']
            auth_opts.delete('data')
            auth_opts.delete('krb_transform_request')
            auth_opts.delete('krb_transform_response')
          end

          begin
            # Send the auth request
            r = request_cgi(auth_opts)
            resp = _send_recv(r, to)
            unless resp.is_a? Rex::Proto::Http::Response
              return nil
            end

            # Get the challenge and craft the response
            response = resp.headers['WWW-Authenticate'].scan(/Kerberos ([A-Z0-9\x2b\x2f=]+)/ni).flatten[0]
            return resp unless response

            decoded = Rex::Text.decode_base64(response)
            mutual_auth_result = kerberos_authenticator.parse_gss_init_response(decoded, auth_result[:session_key])
            self.krb_encryptor = kerberos_authenticator.get_message_encryptor(mutual_auth_result[:ap_rep_subkey],
                                                                              auth_result[:client_sequence_number],
                                                                              mutual_auth_result[:server_sequence_number])

            if opts['no_body_for_auth']
              # If the body wasn't sent in the authentication, now do the actual request
              r = request_cgi(opts)
              resp = _send_recv(r, to, true)
            end
            return resp
          rescue ::Errno::EPIPE, ::Timeout::Error
            return nil
          end
        end

        #
        # Builds a series of requests to complete Negotiate Auth. Works essentially
        # the same way as Digest auth. Same pipelining concerns exist.
        #
        # @option opts (see #send_request_cgi)
        # @option opts provider ["Negotiate","NTLM"] What Negotiate provider to use
        #
        # @return [Response] the last valid HTTP response we received
        def negotiate_auth(opts = {})
          to = opts['timeout'] || 20
          opts['username'] ||= ''
          opts['password'] ||= ''

          if opts['provider'] and opts['provider'].include? 'Negotiate'
            provider = 'Negotiate '
          else
            provider = 'NTLM '
          end

          opts['method'] ||= 'GET'
          opts['headers'] ||= {}

          workstation_name = Rex::Text.rand_text_alpha(rand(6..13))
          domain_name = config['domain']

          ntlm_client = ::Net::NTLM::Client.new(
            opts['username'],
            opts['password'],
            workstation: workstation_name,
            domain: domain_name
          )
          type1 = ntlm_client.init_context

          begin
            # Separate options for the auth requests
            auth_opts = opts.clone
            auth_opts['headers'] = opts['headers'].clone
            auth_opts['headers']['Authorization'] = provider + type1.encode64

            if auth_opts['no_body_for_auth']
              auth_opts.delete('data')
              auth_opts.delete('ntlm_transform_request')
              auth_opts.delete('ntlm_transform_response')
            end

            # First request to get the challenge
            r = request_cgi(auth_opts)
            resp = _send_recv(r, to)
            unless resp.is_a? Rex::Proto::Http::Response
              return nil
            end

            return resp unless resp.code == 401 && resp.headers['WWW-Authenticate']

            # Get the challenge and craft the response
            ntlm_challenge = resp.headers['WWW-Authenticate'].scan(/#{provider}([A-Z0-9\x2b\x2f=]+)/ni).flatten[0]
            return resp unless ntlm_challenge

            ntlm_message_3 = ntlm_client.init_context(ntlm_challenge, channel_binding)

            self.ntlm_client = ntlm_client
            # Send the response
            auth_opts['headers']['Authorization'] = "#{provider}#{ntlm_message_3.encode64}"
            r = request_cgi(auth_opts)
            resp = _send_recv(r, to, true)

            unless resp.is_a? Rex::Proto::Http::Response
              return nil
            end

            if opts['no_body_for_auth']
              # If the body wasn't sent in the authentication, now do the actual request
              r = request_cgi(opts)
              resp = _send_recv(r, to, true)
            end
            return resp
          rescue ::Errno::EPIPE, ::Timeout::Error
            return nil
          end
        end

        def channel_binding
          if !conn.respond_to?(:peer_cert) or conn.peer_cert.nil?
            nil
          else
            Net::NTLM::ChannelBinding.create(OpenSSL::X509::Certificate.new(conn.peer_cert))
          end
        end

        # Read a response from the server
        #
        # Wait at most t seconds for the full response to be read in.
        # If t is specified as a negative value, it indicates an indefinite wait cycle.
        # If t is specified as nil or 0, it indicates no response parsing is required.
        #
        # @return [Response]
        def read_response(t = -1, opts = {})
          # Return a nil response if timeout is nil or 0
          return if t.nil? || t == 0

          resp = Response.new
          resp.max_data = config['read_max_data']

          original_request = opts.fetch(:original_request) { nil }
          parse_opts = {}
          unless original_request.nil?
            parse_opts = { orig_method: original_request.opts['method'] }
          end

          Timeout.timeout((t < 0) ? nil : t) do
            rv = nil
            while (
                     !conn.closed? and
                     rv != Packet::ParseCode::Completed and
                     rv != Packet::ParseCode::Error
                   )

              begin
                buff = conn.get_once(resp.max_data, 1)
                rv = resp.parse(buff || '', parse_opts)

              # Handle unexpected disconnects
              rescue ::Errno::EPIPE, ::EOFError, ::IOError
                case resp.state
                when Packet::ParseState::ProcessingHeader
                  resp = nil
                when Packet::ParseState::ProcessingBody
                  # truncated request, good enough
                  resp.error = :truncated
                end
                break
              end

              # This is a dirty hack for broken HTTP servers
              next unless rv == Packet::ParseCode::Completed

              rbody = resp.body
              rbufq = resp.bufq

              rblob = rbody.to_s + rbufq.to_s
              tries = 0
              begin
                # XXX: This doesn't deal with chunked encoding
                while tries < 1000 and resp.headers['Content-Type'] and resp.headers['Content-Type'].start_with?('text/html') and rblob !~ %r{</html>}i
                  buff = conn.get_once(-1, 0.05)
                  break if !buff

                  rblob += buff
                  tries += 1
                end
              rescue ::Errno::EPIPE, ::EOFError, ::IOError
              end

              resp.bufq = ''
              resp.body = rblob
            end
          end

          return resp if !resp

          # As a last minute hack, we check to see if we're dealing with a 100 Continue here.
          # Most of the time this is handled by the parser via check_100()
          if resp.proto == '1.1' and resp.code == 100 and !(opts[:skip_100])
            # Read the real response from the body if we found one
            # If so, our real response became the body, so we re-parse it.
            if resp.body.to_s =~ /^HTTP/
              body = resp.body
              resp = Response.new
              resp.max_data = config['read_max_data']
              resp.parse(body, parse_opts)
            # We found a 100 Continue but didn't read the real reply yet
            # Otherwise reread the reply, but don't try this hack again
            else
              resp = read_response(t, skip_100: true)
            end
          end

          resp
        rescue Timeout::Error
          # Allow partial response due to timeout
          resp if config['partial']
        end

        #
        # Cleans up any outstanding connections and other resources.
        #
        def stop
          close
        end

        #
        # Returns whether or not the conn is valid.
        #
        def conn?
          conn != nil
        end

        #
        # Whether or not connections should be pipelined.
        #
        def pipelining?
          pipeline
        end

        #
        # Target host addr and port for this connection
        #
        def peerinfo
          if conn
            pi = conn.peerinfo || nil
            if pi
              return {
                'addr' => pi.split(':')[0],
                'port' => pi.split(':')[1].to_i
              }
            end
          end
          nil
        end

        #
        # An optional comm to use for creating the underlying socket.
        #
        attr_accessor :comm
        #
        # The client request configuration
        #
        attr_accessor :config
        #
        # The client request configuration classes
        #
        attr_accessor :config_types
        #
        # Whether or not pipelining is in use.
        #
        attr_accessor :pipeline
        #
        # The local host of the client.
        #
        attr_accessor :local_host
        #
        # The local port of the client.
        #
        attr_accessor :local_port
        #
        # The underlying connection.
        #
        attr_accessor :conn
        #
        # The calling context to pass to the socket
        #
        attr_accessor :context
        #
        # The proxy list
        #
        attr_accessor :proxies

        # Auth
        attr_accessor :username, :password, :kerberos_authenticator

        # When parsing the request, thunk off the first response from the server, since junk
        attr_accessor :junk_pipeline

        # @return [Rex::Proto::Http::HttpSubscriber] The HTTP subscriber
        attr_accessor :subscriber

        protected

        # https
        attr_accessor :ssl, :ssl_version # :nodoc:

        attr_accessor :hostname, :port # :nodoc:

        #
        # The SSL key log file for the connected socket.
        #
        # @return [String]
        attr_accessor :sslkeylogfile

        #
        # The established NTLM connection info
        #
        attr_accessor :ntlm_client

        #
        # The established kerberos connection info
        #
        attr_accessor :krb_encryptor
      end
    end
  end
end
