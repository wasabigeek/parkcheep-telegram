require 'telegram/bot'
require 'active_support/time'
require 'parkcheep'

class BaseState
  def initialize(bot)
    @bot = bot
  end

  def welcome(message)
    @bot.api.send_message(chat_id: message.chat.id, text: "Hello, #{message.from.first_name}")
  end

  def handle(message)
    @bot.api.send_message(chat_id: message.chat.id, text: "Message received, #{message.text}")
  end

  def handle_callback(callback_query)
    @bot.api.send_message(chat_id: callback_query.from.id, text: "Callback received, data: #{callback_query.data}")
  end
end

class SearchState < BaseState
  def initialize(bot)
    @bot = bot
    @search_query = nil
    @location_results = []
  end

  def welcome(message)
    @bot.api.send_message(chat_id: message.chat.id, text: "Hi #{message.from.first_name}, please enter a location to search for.")
  end

  def handle(message)
    if @search_query.nil?
      @search_query = message.text
      @bot.api.send_message(chat_id: message.chat.id, text: "Searching for \"#{@search_query}\"...")
      @location_results = []
      @location_results = Parkcheep::Geocoder.new.geocode(@search_query)
      if @location_results.empty?
        @bot.api.send_message(chat_id: message.chat.id, text: "No locations found.")
        return
      end

      locations = []
      @location_results.each_with_index { |location, index| locations << [index, location.dig(:raw_data, "ADDRESS")] }
      # if locations.size > 1
        kb = locations.map do |result|
          Telegram::Bot::Types::InlineKeyboardButton.new(text: "#{result[1]}", callback_data: result[0].to_s)
        end
        markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
        @bot.api.send_message(chat_id: message.chat.id, text: "Choose the location that matches your search:", reply_markup: markup)
      # elsif locations.size == 1
      #   location = locations.first
      #   @bot.api.send_message(chat_id: message.chat.id, text: "Found this location: #{locations.first[1]}")
      #   # send a callback?
      # end
    end
  end

  def handle_callback(callback_query)
    location = @location_results[callback_query.data.to_i]
    carpark_results = Parkcheep::Carpark.search(destination: location[:coordinate_group]) do |carpark_result|
      carpark_result.distance_from_destination < 1
    end.first(5)

    start_time = Time.current
    end_time = Time.current + 1.hour # note: time helpers are from Parkcheep gem, may want to encapsulate
    @bot.api.send_message(chat_id: callback_query.from.id, text: "Showing first #{carpark_results.size} carparks for #{start_time.to_fs(:short)} to #{end_time.to_fs(:short)}:")
    carpark_results.each do |result|
      estimated_cost = result.carpark.cost(start_time, end_time).truncate(2)
      text = "#{result.name}\n- Distance: #{result.distance_from_destination.truncate(2)} km\n- Estimated Cost: $#{estimated_cost}"

      parking_rate_text = result.carpark.cost_text(start_time, end_time)
      text += "\n- Parking Rates: #{parking_rate_text}" if parking_rate_text.present?

      @bot.api.send_message(
        chat_id: callback_query.from.id,
        text:
      )
    end
  end
end


class Bot
  def initialize
    @token = File.read("telegram_token.txt").strip
    @state = nil
  end

  def run
    puts "Preloading Parkcheep..."
    Time.zone = "Asia/Singapore"
    Parkcheep.preload
    puts "Preloaded Parkcheep!"

    Telegram::Bot::Client.run(@token) do |bot|
      @state = BaseState.new(bot)
      bot.api.set_my_commands(commands: [
        Telegram::Bot::Types::BotCommand.new(command: "start", description: "Start finding carparks at your destination"),
      ])

      bot.listen do |message|
        puts message.class
        case message
        when Telegram::Bot::Types::Message
          case message.text
          when "/start"
            @state = SearchState.new(bot)
            @state.welcome(message)
          when "/stop"
            @state = BaseState.new(bot)
            @state.welcome(message)
          else
            @state.handle(message)
          end
        when Telegram::Bot::Types::CallbackQuery
          @state.handle_callback(message)
        end
      end
    end
  end
end

Bot.new.run
