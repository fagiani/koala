module Koala
  class Response
    attr_reader :status, :body, :headers
    def initialize(status, body, headers)
      @status = status
      @body = body
      @headers = headers
    end
  end

  module HTTPService
    # common functionality for all HTTP services
    def self.included(base)
      base.class_eval do
        class << self
          attr_accessor :always_use_ssl
        end
        
        protected
        def self.params_require_multipart?(param_hash)
          param_hash.any? { |key, value| is_valid_file_hash?(value) }
        end
        
        # A file hash can take two forms:
        # - A hash with "content_type" and "path" keys where "path" is the local path
        #   to the file to be uploaded.
        # - A hash with the "file" key containing an already-opened IO that responds to "read"
        #   as well as "content_type" and the "path" key to the original file
        #   ("path"" is required by multipart-post even for opened files)
        #
        # Valid inputs for a file to be posted via multipart/form-data
        # are based on the criteria for an UploadIO to be created 
        # See : https://github.com/nicksieger/multipart-post/blob/master/lib/composite_io.rb       
        def self.is_valid_file_hash?(value)
          value.kind_of?(Hash) and value.key?("content_type") and value.key?("path") and (
            !value.key?("file") or value["file"].respond_to?(:read)
          )
        end
      end
    end
  end

  module NetHTTPService
    # this service uses Net::HTTP to send requests to the graph
    def self.included(base)
      base.class_eval do
        require "net/http" unless defined?(Net::HTTP)
        require "net/https"
        require "net/http/post/multipart"

        include Koala::HTTPService

        def self.make_request(path, args, verb, options = {})
          # We translate args to a valid query string. If post is specified,
          # we send a POST request to the given path with the given arguments.

          # by default, we use SSL only for private requests
          # this makes public requests faster
          private_request = args["access_token"] || @always_use_ssl || options[:use_ssl]

          # if the verb isn't get or post, send it as a post argument
          args.merge!({:method => verb}) && verb = "post" if verb != "get" && verb != "post"

          server = options[:rest_api] ? Facebook::REST_SERVER : Facebook::GRAPH_SERVER
          http = Net::HTTP.new(server, private_request ? 443 : nil)
          http.use_ssl = true if private_request

          # we turn off certificate validation to avoid the
          # "warning: peer certificate won't be verified in this SSL session" warning
          # not sure if this is the right way to handle it
          # see http://redcorundum.blogspot.com/2008/03/ssl-certificates-and-nethttps.html
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE

          result = http.start do |http|
            response, body = if verb == "post"
              if params_require_multipart? args
                http.request Net::HTTP::Post::Multipart.new path, encode_multipart_params(args)
              else
                http.post(path, encode_params(args))
              end
            else
              http.get("#{path}?#{encode_params(args)}")
            end
            
            Koala::Response.new(response.code.to_i, body, response)
          end
        end

        protected
        def self.encode_params(param_hash)
          # unfortunately, we can't use to_query because that's Rails, not Ruby
          # if no hash (e.g. no auth token) return empty string
          ((param_hash || {}).collect do |key_and_value|
            key_and_value[1] = key_and_value[1].to_json if key_and_value[1].class != String
            "#{key_and_value[0].to_s}=#{CGI.escape key_and_value[1]}"
          end).join("&")
        end
        
        def self.encode_multipart_params(param_hash)
          Hash[*param_hash.collect do |key, value| 
            if is_valid_file_hash?(value)
              if value.key?("file")
                value = UploadIO.new(value["file"], value["content_type"], value["path"])
              else
                value = UploadIO.new(value["path"], value['content_type'])
              end
            end
            
            [key, value]
          end.flatten]
        end
      end
    end
  end

  module TyphoeusService
    # this service uses Typhoeus to send requests to the graph

    # used for multipart file uploads (see below)
    class NetHTTPInterface
      include NetHTTPService
    end

    def self.included(base)
      base.class_eval do
        require "typhoeus" unless defined?(Typhoeus)
        include Typhoeus
        
        include Koala::HTTPService

        def self.make_request(path, args, verb, options = {})
          unless params_require_multipart?(args)
            # if the verb isn't get or post, send it as a post argument
            args.merge!({:method => verb}) && verb = "post" if verb != "get" && verb != "post"
            server = options[:rest_api] ? Facebook::REST_SERVER : Facebook::GRAPH_SERVER

            # you can pass arguments directly to Typhoeus using the :typhoeus_options key
            typhoeus_options = {:params => args}.merge(options[:typhoeus_options] || {})

            # by default, we use SSL only for private requests (e.g. with access token)
            # this makes public requests faster
            prefix = (args["access_token"] || @always_use_ssl || options[:use_ssl]) ? "https" : "http"

            response = self.send(verb, "#{prefix}://#{server}#{path}", typhoeus_options)
            Koala::Response.new(response.code, response.body, response.headers_hash)
          else
            # we have to use NetHTTPService for multipart for file uploads
            # until Typhoeus integrates support
            Koala::TyphoeusService::NetHTTPInterface.make_request(path, args, verb, options)
          end
        end
      end # class_eval
    end
  end
end