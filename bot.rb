require 'telegram/bot'
require 'parkcheep'

class NullState
  def initialize(bot)
    @bot = bot
  end

  def welcome(message)
    @bot.api.send_message(chat_id: message.chat.id, text: "Hello, #{message.from.first_name}")
  end

  def handle(message)
    @bot.api.send_message(chat_id: message.chat.id, text: "Hello again, #{message.from.first_name}")
  end
end

class SearchState
  def initialize(bot)
    @bot = bot
    @search_query = nil
  end

  def welcome(message)
    @bot.api.send_message(chat_id: message.chat.id, text: "Hi #{message.from.first_name}, please enter a location to search for.")
  end

  def handle(message)
    if @search_query.nil?
      @search_query = message.text
      @bot.api.send_message(chat_id: message.chat.id, text: "Searching for carparks near \"#{@search_query}\"...")
      locations = Parkcheep::Geocoder.new.geocode(@search_query)
      if locations.empty?
        @bot.api.send_message(chat_id: message.chat.id, text: "No carparks found.")
        return
      end

      location_results = []
      locations.each_with_index { |location, index| location_results << [index, location.dig(:raw_data, "ADDRESS")] }
      if location_results.size > 1
        @bot.api.send_message(chat_id: message.chat.id, text: "Found these locations matching #{@search_query}:")
        location_results.each do |result|
          @bot.api.send_message(chat_id: message.chat.id, text: "#{result[0]}: #{result[1]}")
        end

        # puts "Enter the number nearest to your destination. We'll search for carparks nearby:"
        # print "> "
        # location_index = gets.chomp.to_i
        # location = locations[location_index]
      else
        location = locations.first
        @bot.api.send_message(chat_id: message.chat.id, text: "Found this location: #{location_results.first[1]}")
      end
    end
  end
end


class Bot
  def initialize
    @token = File.read("telegram_token.txt").strip
    @state = nil
  end

  def run
    Telegram::Bot::Client.run(@token) do |bot|
      @state = NullState.new(bot)
      bot.api.set_my_commands(commands: [
        Telegram::Bot::Types::BotCommand.new(command: "start", description: "Start finding carparks at your destination"),
      ])

      bot.listen do |message|
        case message.text
        # when /\/*./
        when "/start"
          @state = SearchState.new(bot)
          @state.welcome(message)
        when "/stop"
          @state = NullState.new(bot)
          @state.welcome(message)
        else
          @state.handle(message)
        end

      end
    end
  end
end

Bot.new.run
