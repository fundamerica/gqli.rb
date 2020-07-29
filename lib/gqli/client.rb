# frozen_string_literal: true

require 'http'
require 'json'
require_relative './response'
require_relative './introspection'
require_relative './version'

module GQLi
  # GraphQL HTTP Client
  class Client
    attr_reader :url, :params, :headers, :validate_query, :validate_unknown_types, :schema

    def initialize(url, params: {}, headers: {}, validate_query: true, validate_unknown_types: true)
      @url = url
      @params = params
      @headers = headers
      @validate_query = validate_query

      @validate_unknown_types = validate_unknown_types
      @schema = Introspection.new(self) if validate_query
    end

    # Executes a query
    # If validations are enabled, will perform validation check before request.
    def execute(query)
      if validate_query
        validation = schema.validate(query)
        fail validation_error_message(validation) unless validation.valid?
      end

      execute!(query)
    end

    # Executres a query
    # Ignores validations
    def execute!(query)
      http_response = HTTP.headers(request_headers).post(@url, params: @params, json: { query: query.to_gql })

      fail "Error: #{http_response.reason}\nBody: #{http_response.body}" if http_response.status >= 300

      parsed_response = JSON.parse(http_response.to_s)
      data = parsed_response.fetch('data', [])
      errors = get_errors(parsed_response)

      Response.new(data, query, errors.compact.flatten)
    end

    # Recursively get any errors contained within the data
    def get_errors(value)
      errors = []
      if value.is_a?(Hash)
        return value['errors'] if value['errors']
        value.each do |k,v|
          errors << get_errors(v)
        end
      end

      if value.is_a?(Array)
        value.each { |el| errors << get_errors(el) }
      end

      errors.compact.flatten
    end

    # Validates a query against the schema
    def valid?(query)
      return true unless validate_query

      schema.valid?(query)
    end

    protected

    def validation_error_message(validation)
      <<~ERROR
        Validation Error: query is invalid - HTTP Request not sent.

        Errors:
          - #{validation.errors.join("\n  - ")}
      ERROR
    end

    def request_headers
      {
        accept: 'application/json',
        user_agent: "gqli.rb/#{VERSION}; http.rb/#{HTTP::VERSION}"
      }.merge(@headers)
    end
  end
end
