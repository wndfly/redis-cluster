# frozen_string_literal: true
# encoding: UTF-8

require 'simplecov'
require 'codecov'

require_relative 'helper/fake_redis_cluster'
require_relative 'helper/shared_example_function'

SimpleCov.formatter =
  if ENV['CI']
    SimpleCov::Formatter::Codecov
  else
    SimpleCov::Formatter::HTMLFormatter
  end

SimpleCov.start
