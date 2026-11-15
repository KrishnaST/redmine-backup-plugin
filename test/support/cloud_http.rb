# frozen_string_literal: true

class CloudHttp
  attr_reader :requests

  def initialize(*responses)
    @responses, @requests = responses, []
  end

  def request(method, url, **options)
    @requests << [method, url, options]
    response = @responses.shift || raise('Unexpected HTTP request')
    Struct.new(:code, :body).new(response.fetch(:status, 200).to_s, JSON.generate(response.fetch(:data)))
  end

  def json!(response)
    raise RedmineBackup::Error, 'TEST_HTTP_FAILURE' unless response.code.to_i.between?(200, 299)
    JSON.parse(response.body)
  end
end
