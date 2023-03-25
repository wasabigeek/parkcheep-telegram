require 'telegram/bot'
require 'active_support/hash_with_indifferent_access'
require 'active_support/time'
require 'parkcheep'

class BaseState
  attr_reader :next_state

  def self.enter(bot, **kwargs)
    new(bot, **kwargs).tap { |state| state.welcome }
  end

  def initialize(bot, **kwargs)
    @bot = bot
    @next_state = self
    @chat = kwargs[:chat]
  end

  def handle(message)
    @bot.api.send_message(chat_id: message.chat.id, text: "Message received, #{message.text}")

    @next_state = self
  end

  def handle_callback(callback_query)
    @bot.api.send_message(chat_id: callback_query.from.id, text: "Callback received, data: #{callback_query.data}")

    @next_state = self
  end

  def welcome
    return unless @chat.present?

    @bot.api.send_message(chat_id: @chat.id, text: "Hello, welcome to the Parkcheep Bot! Type /start to begin.")
  end
end

class SearchState < BaseState
  def initialize(bot, **kwargs)
    @search_query = nil
    @location_results = []

    super
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
      @location_results.each_with_index { |location, index| locations << [index, location[:address]] }

      # TODO: fix to work with multiple locations
      center_location = @location_results.first
      center_lat_lng = [center_location[:coordinate_group].latitude, center_location[:coordinate_group].longitude].join(",")
      @bot.api.send_photo(
        chat_id: message.chat.id,
        photo: "https://maps.googleapis.com/maps/api/staticmap?center=#{center_lat_lng}&zoom=17&size=400x400&markers=label:A|#{center_lat_lng}&key=#{ENV["GOOGLE_MAPS_API_KEY"]}" # &signature=#{}
      )
      # if locations.size > 1
        kb = locations.map do |result|
          Telegram::Bot::Types::InlineKeyboardButton.new(text: "A: #{result[1]}", callback_data: result[0].to_s)
        end
        markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
        @bot.api.send_message(chat_id: message.chat.id, text: "Choose the location that matches your search:", reply_markup: markup)
      # elsif locations.size == 1
      #   location = locations.first
      #   @bot.api.send_message(chat_id: message.chat.id, text: "Found this location: #{locations.first[1]}")
      #   # send a callback?
      # end
    end

    @next_state = self
  end

  def handle_callback(callback_query)
    location = @location_results[callback_query.data.to_i]
    @next_state = SelectTimeState.enter(@bot, chat: @chat, destination: location[:coordinate_group])
  end

  def welcome
    return unless @chat.present?

    @bot.api.send_message(chat_id: @chat.id, text: "Please enter a location to search for.")
  end
end

class SelectTimeState < BaseState
  def initialize(bot, **kwargs)
    @destination = kwargs[:destination]
    @start_time = Time.current
    @end_time = start_time + 1.hour # note: time helpers are from Parkcheep gem, may want to encapsulate

    super
  end

  def welcome
    kb = [
      Telegram::Bot::Types::InlineKeyboardButton.new(text: "Yes", callback_data: "yes"),
      Telegram::Bot::Types::InlineKeyboardButton.new(text: "No", callback_data: "no")
    ]
    markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
    @bot.api.send_message(chat_id: @chat.id, text: "Time period is set to #{start_time.to_fs(:short)} to #{end_time.to_fs(:short)}, is this correct?", reply_markup: markup)
  end

  def handle_callback(callback_query)
    if callback_query.data == "yes"
      @next_state = ShowCarparksState.enter(@bot, chat: @chat, destination: @destination, start_time: @start_time, end_time: @end_time)
    else
      @bot.api.send_message(chat_id: @chat.id, text: "Please enter a start time in HH:MM format (e.g. 13:15).")
    end
  end

  def handle(message)
    begin
      @start_time = Time.parse(message.text)
      @end_time = start_time + 1.hour
      welcome
    rescue ArgumentError => e
      puts e
      @bot.api.send_message(chat_id: message.chat.id, text: "Could not parse \"#{message.text}\", please try again in HH:MM format.")
    end
  end

  private

  attr_reader :start_time, :end_time
end


class ShowCarparksState < BaseState
  def initialize(bot, **kwargs)
    @destination = kwargs[:destination]
    @start_time = kwargs[:start_time]
    @end_time = kwargs[:end_time]

    super
  end

  def welcome
    carpark_results = Parkcheep::Carpark.search(destination: @destination) do |carpark_result|
      carpark_result.distance_from_destination < 1
    end.first(5)

    @bot.api.send_message(
      chat_id: @chat.id,
      text: "Showing first #{carpark_results.size} carparks for #{start_time.to_fs(:short)} to #{end_time.to_fs(:short)}:"
    )
    carpark_results.each do |result|
      estimated_cost = result.carpark.cost(start_time, end_time)
      estimated_cost_text = estimated_cost.nil? ? "N/A" : "$#{estimated_cost.truncate(2)}"
      text = "#{result.name}\n- Distance: #{result.distance_from_destination.truncate(2)} km"
      text += "\n- Estimated Cost: #{estimated_cost_text}"

      parking_rate_text = result.carpark.cost_text(start_time, end_time)
      text += "\n- Parking Rates: #{parking_rate_text}" if parking_rate_text.present?

      coord = result.carpark.coordinate_group
      # $gmaps$ is a workaround to not escape inline url
      text += "\n- $gmaps$https://www.google.com/maps/dir/?api=1&destination=#{[coord.latitude, coord.longitude].join(",")}$gmaps$"

      # escape Telegram markdown reserved characters https://core.telegram.org/bots/api#formatting-options
      text.gsub!(/(\_|\*|\~|\`|\>|\#|\+|\-|\=|\||\{|\}|\.|\!|\[|\]|\(|\))/) { |match| "\\#{match}" }
      text.gsub!(/\$gmaps\$(\S+)\$gmaps\$/, "[Google Maps](\\1)")

      @bot.api.send_message(
        chat_id: @chat.id,
        text:,
        parse_mode: "MarkdownV2",
      )
    end
  end

  private

  attr_reader :start_time, :end_time
end

class Bot
  def initialize
    @token = ENV["TELEGRAM_TOKEN"] || File.read("telegram_token.txt").strip
    @state = nil
    @chat_state_store = Hash.new do |_, k|
      {
        chat_id: k,
        state: BaseState.to_s,
      }
    end
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
        case message
        when Telegram::Bot::Types::Message
          puts "#{message.class}"
          case message.text
          when "/start"
            # state = SearchState.enter(
            @state = SearchState.enter(
              bot,
              chat: message.chat
            )
            # @chat_state_store[message.chat.id] = state.serialize
          when "/stop"
            # state = BaseState.enter(
            @state = BaseState.enter(
              bot,
              chat: message.chat
            )
            # @chat_state_store[message.chat.id] = state.serialize
          else
            # data = @chat_state_store[message.chat.id]
            # state_class = data.delete(:state).constantize
            # state = state_class.deserialize(bot, **data)
            # state.handle(message)
            # @chat_state_store[message.chat.id] = state.next_state.serialize

            @state.handle(message)
            @state = @state.next_state
          end
        when Telegram::Bot::Types::CallbackQuery
          puts "CallbackQuery ID #{message.id}: #{message.data}"
          @state.handle_callback(message)
          @state = @state.next_state
        end
      end
    end
  end
end

Bot.new.run
