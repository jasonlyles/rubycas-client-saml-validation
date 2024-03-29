module CASClient
  # The client brokers all HTTP transactions with the CAS server.
  class Client
    attr_reader :cas_base_url, :cas_destination_logout_param_name
    attr_reader :log, :username_session_key, :extra_attributes_session_key
    attr_reader :ticket_store
    attr_writer :login_url, :validate_url, :proxy_url, :logout_url, :service_url
    attr_accessor :proxy_callback_url, :proxy_retrieval_url
    
    def initialize(conf = nil)
      configure(conf) if conf
    end
    
    def configure(conf)
      #TODO: raise error if conf contains unrecognized cas options (this would help detect user typos in the config)

      raise ArgumentError, "Missing :cas_base_url parameter!" unless conf[:cas_base_url]
      
      if conf.has_key?("encode_extra_attributes_as")
        unless (conf[:encode_extra_attributes_as] == :json || conf[:encode_extra_attributes_as] == :yaml)
          raise ArgumentError, "Unkown Value for :encode_extra_attributes_as parameter! Allowed options are json or yaml - #{conf[:encode_extra_attributes_as]}"
        end
      end
   
      @cas_base_url      = conf[:cas_base_url].gsub(/\/$/, '')       
      @cas_destination_logout_param_name = conf[:cas_destination_logout_param_name]
      
      @login_url    = conf[:login_url]
      @logout_url   = conf[:logout_url]
      @validate_url = conf[:validate_url]
      @proxy_url    = conf[:proxy_url]
      @service_url  = conf[:service_url]
      @force_ssl_verification  = conf[:force_ssl_verification]
      @proxy_callback_url  = conf[:proxy_callback_url]
      
      @username_session_key         = conf[:username_session_key] || :cas_user
      @extra_attributes_session_key = conf[:extra_attributes_session_key] || :cas_extra_attributes
      @ticket_store_class = case conf[:ticket_store]
        when :local_dir_ticket_store, nil
          CASClient::Tickets::Storage::LocalDirTicketStore
        when :active_record_ticket_store
          ::ACTIVE_RECORD_TICKET_STORE
        else
          conf[:ticket_store]
      end
      @ticket_store = @ticket_store_class.new conf[:ticket_store_config]
      raise CASException, "The Ticket Store is not a subclass of AbstractTicketStore, it is a #{@ticket_store_class}" unless @ticket_store.kind_of? CASClient::Tickets::Storage::AbstractTicketStore
      
      @log = CASClient::LoggerWrapper.new
      @log.set_real_logger(conf[:logger]) if conf[:logger]
      @ticket_store.log = @log
      @conf_options = conf
    end
    
    def cas_destination_logout_param_name
      @cas_destination_logout_param_name || "destination"
    end

    def login_url
      @login_url || (cas_base_url + "/login")
    end
    
    def validate_url
      @validate_url || (cas_base_url + "/proxyValidate")
    end
    
    # Returns the CAS server's logout url.
    #
    # If a logout_url has not been explicitly configured,
    # the default is cas_base_url + "/logout".
    #
    # destination_url:: Set this if you want the user to be
    #                   able to immediately log back in. Generally
    #                   you'll want to use something like <tt>request.referer</tt>.
    #                   Note that the above behaviour describes RubyCAS-Server 
    #                   -- other CAS server implementations might use this
    #                   parameter differently (or not at all).
    # follow_url:: This satisfies section 2.3.1 of the CAS protocol spec.
    #              See http://www.ja-sig.org/products/cas/overview/protocol
    def logout_url(destination_url = nil, follow_url = nil)
      url = @logout_url || (cas_base_url + "/logout")
      
      if destination_url
        # if present, remove the 'ticket' parameter from the destination_url
        duri = URI.parse(destination_url)
        h = duri.query ? query_to_hash(duri.query) : {}
        h.delete('ticket')
        duri.query = hash_to_query(h)
        destination_url = duri.to_s.gsub(/\?$/, '')
      end
      
      if destination_url || follow_url
        uri = URI.parse(url)
        h = uri.query ? query_to_hash(uri.query) : {}
        h[cas_destination_logout_param_name] = destination_url if destination_url
        h['url'] = follow_url if follow_url
        uri.query = hash_to_query(h)
        uri.to_s
      else
        url
      end
    end
    
    def proxy_url
      @proxy_url || (cas_base_url + "/proxy")
    end
    
    def validate_service_ticket(st)
      uri = URI.parse(validate_url)
      h = uri.query ? query_to_hash(uri.query) : {}
      h['service'] = st.service
      h['ticket'] = st.ticket
      h['renew'] = "1" if st.renew
      h['pgtUrl'] = proxy_callback_url if proxy_callback_url
      uri.query = hash_to_query(h)

      if uri.path == '/sso/samlValidate'
        response = request_cas_validation_response(uri, ValidationResponse)
      else
        response = request_cas_response(uri, ValidationResponse)
      end
      st.user = response.user
      st.extra_attributes = response.extra_attributes
      st.pgt_iou = response.pgt_iou
      st.success = response.is_success?
      st.failure_code = response.failure_code
      st.failure_message = response.failure_message
      
      return st
    end
    alias validate_proxy_ticket validate_service_ticket
    
    # Returns true if the configured CAS server is up and responding;
    # false otherwise.
    def cas_server_is_up?
      uri = URI.parse(login_url)
      
      log.debug "Checking if CAS server at URI '#{uri}' is up..."
      
      https = Net::HTTP.new(uri.host, uri.port)
      https.use_ssl = (uri.scheme == 'https')
      https.verify_mode = (@force_ssl_verification ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE)
      
      begin
        raw_res = https.start do |conn|
          conn.get("#{uri.path}?#{uri.query}")
        end
      rescue Errno::ECONNREFUSED => e
        log.warn "CAS server did not respond! (#{e.inspect})"
        return false
      end
      
      log.debug "CAS server responded with #{raw_res.inspect}:\n#{raw_res.body}"
      
      return raw_res.kind_of?(Net::HTTPSuccess)
    end

    #This method exists only to get the servers time by making a light request and getting the response header date
    def get_cas_server_time
      uri = URI.parse(@cas_base_url)

      log.debug "Getting a timestamp from the CAS server at URI '#{uri}'"

      https = Net::HTTP.new(uri.host, uri.port)
      https.use_ssl = (uri.scheme == 'https')
      https.verify_mode = (@force_ssl_verification ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE)

      begin
        raw_res = https.start do |conn|
          conn.get("#{uri.path}?#{uri.query}")
        end
      rescue Errno::ECONNREFUSED => e
        log.warn "CAS server did not respond! (#{e.inspect})"
        return false
      end

      log.debug "CAS server responded with #{raw_res.inspect}:\n#{raw_res.body}"

      if raw_res.kind_of?(Net::HTTPSuccess) || raw_res.kind_of?(Net::HTTPRedirection)
        return raw_res.header['date']
      else
        return false
      end
    end
    
    # Requests a login using the given credentials for the given service; 
    # returns a LoginResponse object.
    def login_to_service(credentials, service)
      lt = request_login_ticket
      
      data = credentials.merge(
        :lt => lt,
        :service => service 
      )
      
      res = submit_data_to_cas(login_url, data)
      response = CASClient::LoginResponse.new(res)

      if response.is_success?
        log.info("Login was successful for ticket: #{response.ticket.inspect}.")
      end

      return response
    end
  
    # Requests a login ticket from the CAS server for use in a login request;
    # returns a LoginTicket object.
    #
    # This only works with RubyCAS-Server, since obtaining login
    # tickets in this manner is not part of the official CAS spec.
    def request_login_ticket
      uri = URI.parse(login_url+'Ticket')
      https = Net::HTTP.new(uri.host, uri.port)
      https.use_ssl = (uri.scheme == 'https')
      https.verify_mode = (@force_ssl_verification ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE)
      res = https.post(uri.path, ';')
      
      raise CASException, res.body unless res.kind_of? Net::HTTPSuccess
      
      res.body.strip
    end
    
    # Requests a proxy ticket from the CAS server for the given service
    # using the given pgt (proxy granting ticket); returns a ProxyTicket 
    # object.
    #
    # The pgt required to request a proxy ticket is obtained as part of
    # a ValidationResponse.
    def request_proxy_ticket(pgt, target_service)
      uri = URI.parse(proxy_url)
      h = uri.query ? query_to_hash(uri.query) : {}
      h['pgt'] = pgt.ticket
      h['targetService'] = target_service
      uri.query = hash_to_query(h)
      
      response = request_cas_response(uri, ProxyResponse)
      
      pt = ProxyTicket.new(response.proxy_ticket, target_service)
      pt.success = response.is_success?
      pt.failure_code = response.failure_code
      pt.failure_message = response.failure_message
      
      return pt
    end
    
    def retrieve_proxy_granting_ticket(pgt_iou)
      pgt = @ticket_store.retrieve_pgt(pgt_iou)

      raise CASException, "Couldn't find pgt for pgt_iou #{pgt_iou}" unless pgt

      ProxyGrantingTicket.new(pgt, pgt_iou)
    end
    
    def add_service_to_login_url(service_url)
      uri = URI.parse(login_url)
      uri.query = (uri.query ? uri.query + "&" : "") + "service=#{CGI.escape(service_url)}"
      uri.to_s
    end
    
    private
    # Fetches a CAS response of the given type from the given URI.
    # Type should be either ValidationResponse or ProxyResponse.
    def request_cas_response(uri, type, options={})
      log.debug "Requesting CAS response for URI #{uri}"

      uri = URI.parse(uri) unless uri.kind_of? URI
      https = Net::HTTP.new(uri.host, uri.port)
      https.use_ssl = (uri.scheme == 'https')
      https.verify_mode = (@force_ssl_verification ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE)

      begin
        raw_res = https.start do |conn|
          conn.get("#{uri.path}?#{uri.query}")
        end
      rescue Errno::ECONNREFUSED => e
        log.error "CAS server did not respond! (#{e.inspect})"
        raise "The CAS authentication server at #{uri} is not responding!"
      end

      # We accept responses of type 422 since RubyCAS-Server generates these
      # in response to requests from the client that are processable but contain
      # invalid CAS data (for example an invalid service ticket).
      if raw_res.kind_of?(Net::HTTPSuccess) || raw_res.code.to_i == 422
        log.debug "CAS server responded with #{raw_res.inspect}:\n#{raw_res.body}"
      else
        log.error "CAS server responded with an error! (#{raw_res.inspect})"
        raise "The CAS authentication server at #{uri} responded with an error (#{raw_res.inspect})!"
      end

      type.new(raw_res.body, @conf_options)
    end

    def request_cas_validation_response(uri, type, options={})
      log.debug "Requesting CAS response for URI #{uri}"
      request_time = get_cas_server_time
      uri = URI.parse(uri) unless uri.kind_of? URI
      service,ticket = uri.query.split('&')
      target = service.sub('service=','TARGET=')
      ticket = ticket.sub('ticket=','')
      request_id = defined?(UUIDTools) ? UUIDTools::UUID.timestamp_create.to_s : UUID.timestamp_create.to_s
      if request_time == false
        request_time = Time.now.strftime("%Y-%m-%dT%H:%M:%SZ")
      else
        request_time = Time.parse(request_time).strftime("%Y-%m-%dT%H:%M:%SZ")
      end
      soap = "<SOAP-ENV:Envelope xmlns:SOAP-ENV=\"http://schemas.xmlsoap.org/soap/envelope/\"><SOAP-ENV:Header/>
              <SOAP-ENV:Body><samlp:Request xmlns:samlp=\"urn:oasis:names:tc:SAML:1.0:protocol\"  MajorVersion=\"1\"
              MinorVersion=\"1\" RequestID=\"#{request_id}\" IssueInstant=\"#{request_time}\"><samlp:AssertionArtifact>#{ticket}</samlp:AssertionArtifact>
              </samlp:Request></SOAP-ENV:Body></SOAP-ENV:Envelope>"

      https = Net::HTTP.new(uri.host, uri.port)
      https.use_ssl = (uri.scheme == 'https')
      https.verify_mode = (@force_ssl_verification ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE)

      headers = {'Content-Type' => 'application/soap+xml'}
      uri_with_target = "#{uri.path}?#{target}"
      begin
        response, data = https.post(uri_with_target, soap, headers)
      rescue Errno::ECONNREFUSED => e
        log.error "CAS server did not respond! (#{e.inspect})"
        raise "The CAS authentication server at #{uri} is not responding!"
      end

        # We accept responses of type 422 since RubyCAS-Server generates these
        # in response to requests from the client that are processable but contain
        # invalid CAS data (for example an invalid service ticket).

      if response.kind_of?(Net::HTTPSuccess) || response.code.to_i == 422
        log.debug "CAS server responded with #{response.inspect}:\n#{response.body}"
      else
        log.error "CAS server responded with an error! (#{response.inspect})"
        raise "The CAS authentication server at #{uri.host}#{uri.path} responded with an error (#{response.inspect})!"
      end

      type.new(response.body, @conf_options)
    end

    # Submits some data to the given URI and returns a Net::HTTPResponse.
    def submit_data_to_cas(uri, data)
      uri = URI.parse(uri) unless uri.kind_of? URI
      req = Net::HTTP::Post.new(uri.path)
      req.set_form_data(data, ';')
      https = Net::HTTP.new(uri.host, uri.port)
      https.use_ssl = (uri.scheme == 'https')
      https.verify_mode = (@force_ssl_verification ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE)
      https.start {|conn| conn.request(req) }
    end
    
    def query_to_hash(query)
      CGI.parse(query)
    end
      
    def hash_to_query(hash)
      pairs = []
      hash.each do |k, vals|
        vals = [vals] unless vals.kind_of? Array
        vals.each {|v| pairs << (v.nil? ? CGI.escape(k) : "#{CGI.escape(k)}=#{CGI.escape(v)}")}
      end
      pairs.join("&")
    end
  end
end
