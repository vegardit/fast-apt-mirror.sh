# https://github.com/simplecov-ruby/simplecov

require "simplecov-console" # https://github.com/chetan/simplecov-console
SimpleCov.formatter = SimpleCov::Formatter::Console
SimpleCov::Formatter::Console.output_style = 'block'

# exclude folders from the coverage report
SimpleCov.add_filter '/tests/'
SimpleCov.add_filter '/_LOCAL/'
SimpleCov.add_filter '/.git/'