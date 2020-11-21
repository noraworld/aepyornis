# frozen_string_literal: true

require 'sinatra'

post '/' do
  params = JSON.parse(request.body.read)
  pp params
end
