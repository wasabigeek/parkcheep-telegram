# frozen_string_literal: true

source "https://rubygems.org"

gem "parkcheep",
    git: "git@github.com:wasabigeek/parkcheep-prototype.git",
    branch: "main"
gem "telegram-bot-ruby", "~> 0.23.0"
gem "google-cloud-logging", "~> 2.3"

group :development do
  gem "capistrano", "~> 3.17", require: false
  gem "ed25519", "~> 1.3" # for capistrano
  gem "bcrypt_pbkdf", "~> 1.1" # for capistrano
end

group :development, :test do
  gem "byebug", "~> 11.1"
  gem "rspec", "~> 3.12"
end
