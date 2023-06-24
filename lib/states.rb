require "json"
require "openai"

class BaseState
  attr_reader :next_state

  def self.enter(bot, **kwargs)
    init_from_data(bot, **kwargs).tap { |state| state.welcome }
  end

  def self.init_from_data(bot, **data)
    deserialized_data = data.dup
    if deserialized_data.dig(:destination, :coordinate_group)
      deserialized_data[:destination][
        :coordinate_group
      ] = Parkcheep::CoordinateGroup.new(
        **data[:destination][:coordinate_group]
      )
    end
    if deserialized_data[:start_time]
      deserialized_data[:start_time] = Time.zone.parse(data[:start_time])
      deserialized_data[:end_time] = Time.zone.parse(data[:end_time])
    end
    if deserialized_data[:location_results]
      deserialized_data[:location_results] = data[
        :location_results
      ].map do |result_hash|
        {
          address: result_hash[:address],
          coordinate_group:
            Parkcheep::CoordinateGroup.new(**result_hash[:coordinate_group])
        }
      end
    end

    new(bot, **deserialized_data)
  end

  def initialize(bot, **kwargs)
    @bot = bot
    @next_state = self
    @chat_id = kwargs[:chat_id]
    @search_query = kwargs[:search_query]
    @location_results = kwargs[:location_results] || []
    @destination = kwargs[:destination] || { coordinate_group: nil }
    @start_time = kwargs[:start_time] || Time.current + 30.minutes
    @end_time = kwargs[:end_time] || @start_time + 1.hour # note: time helpers are from Parkcheep gem, may want to encapsulate
    @feedback = kwargs[:feedback] || {}
    @carpark_results_index = kwargs[:carpark_results_index] || 0
  end

  def handle(message)
    @next_state = self
  end

  def handle_callback(callback_query)
    @next_state = self
  end

  def to_data
    {
      state: self.class.name,
      chat_id: @chat_id,
      search_query: @search_query,
      location_results:
        @location_results.map do |result|
          {
            address: result[:address],
            coordinate_group: result[:coordinate_group]&.as_json&.symbolize_keys
          }
        end,
      destination: {
        coordinate_group:
          @destination[:coordinate_group]&.as_json&.symbolize_keys
      },
      start_time: @start_time&.iso8601,
      end_time: @end_time&.iso8601,
      feedback: @feedback,
      carpark_results_index: @carpark_results_index
    }
  end

  def welcome
    return unless @chat_id.present?

    @bot.api.send_message(
      chat_id: @chat_id,
      text: "Hello, welcome to the Parkcheep Bot! Type /start to begin."
    )
  end

  # @param [Parkcheep::CoordinateGroup] destination
  # @param [Array<Parkcheep::Carpark>] carparks
  def gmaps_static_url(destination:, carparks: [])
    center_lat_lng = [destination.latitude, destination.longitude].join(",")
    url =
      "https://maps.googleapis.com/maps/api/staticmap?key=" +
        ENV["GOOGLE_MAPS_API_KEY"] # &signature=#{}
    url += "&size=500x500"
    # destination parameters
    url += "&markers=color:red|#{center_lat_lng}"
    # carpark parameters
    carpark_markers =
      carparks.to_enum.with_index.map do |carpark, index|
        labels = %w[A B C D E F G H I J]
        coordinate_group = carpark.coordinate_group
        "&markers=color:yellow|label:#{labels[index]}|#{coordinate_group.latitude},#{coordinate_group.longitude}"
      end
    url += carpark_markers.join if carpark_markers.any?

    url
  end
end

class StartStateV2 < BaseState
  # temp method
  def self.enabled?(chat_id)
    chat_id.to_s == ENV["FEEDBACK_CHAT_ID"] && ENV["OPENAI_API_KEY"].present?
  end

  def welcome
    @bot.api.send_message(chat_id: @chat_id, text: <<~WELCOME)
      👋 Hey there! I'm here to help you find nearby carparks. Just let me know your destination and the arrival/departure time e.g. Ngee Ann City, 10am to 12pm.
    WELCOME
  end

  def handle(message)
    @bot.api.send_message(chat_id: @chat_id, text: "🤖 Processing your request...")
    @search_query, @start_time, @end_time = parse(message.text)
    @next_state = ShowSearchDataState.enter(@bot, **to_data)
  end

  private

  def parse(query)
    query = query.strip
    return if query.blank?

    client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])
    prompt = <<~PROMPT
      Your task is to figure out where the user's destination, arrival and departure time.
      For the text delimited by triple backticks:
        - Extract the destination, assuming it is in Singapore.
        - If provided, extract the arrival and departure time in ISO8601 format, assuming the time now is #{Time.now.to_s}.
        - If possible, geocode the destination and get it's latitude and longitude.
        - Output a json object that contains the following keys: original_text, destination, latitude, longitude, arrival_time, departure_time.

      ```#{query}```
    PROMPT

    response = client.chat(
      parameters: {
      model: "gpt-3.5-turbo",
      messages: [
        {
          "role": "user",
          "content": prompt,
        },
      ],
      temperature: 0,
      max_tokens: 256,
    })
    # TODO: log to track accuracy
    message = response.dig("choices", 0, "message", "content")
    json_string = message.match(/\{.*\}/m).to_s
    json_object = JSON.parse(json_string)

    search_query = json_object["destination"]
    start_time =
      if json_object["arrival_time"]
        Time.zone.parse(json_object["arrival_time"])
      else
        Time.current + 30.minutes
      end
    end_time =
      if json_object["departure_time"]
        Time.zone.parse(json_object["departure_time"])
      else
        @start_time + 1.hour
      end

    [search_query, start_time, end_time]
  end
end

class NaturalSearchState < BaseState
  REGEX =
    /(?<destination>.+) at ?(?<starts_at>(?>\d{4}-\d{2}-\d{2} )?(?>\d{2}:\d{2}))?(?> to (?<ends_at>(?>\d{4}-\d{2}-\d{2} )?(?>\d{2}:\d{2})))?|(?<destination_all>.+)/.freeze
  HELP_TEXT = <<~HELP
    - `[destination]` e.g. Orchard Road
    - `[destination] at [HH:MM]` e.g. Orchard Road at 13:30
    - `[destination] at [HH:MM] to [HH:MM]` e.g. Orchard Road at 13:30 to 15:00
    - `[destination] at [YYYY-MM-DD HH:MM]` e.g. Orchard Road at 2023-04-01 13:30
  HELP

  def welcome
    @bot.api.send_message(chat_id: @chat_id, text: <<~WELCOME)
      👋 Where in Singapore are you going? Type something like this and I'll help find nearby carparks:
      #{HELP_TEXT}
    WELCOME
  end

  def handle(message)
    raw_text = message.text
    match_data = REGEX.match(raw_text)
    if match_data.nil?
      @bot.api.send_message(
        chat_id: message.chat.id,
        text:
          "Sorry, I didn't understand! Please type something like:\n#{HELP_TEXT}"
      )
      return
    end

    @search_query = match_data[:destination_all] || match_data[:destination]
    @start_time =
      (
        if match_data[:starts_at]
          Time.zone.parse(match_data[:starts_at])
        else
          Time.current + 30.minutes
        end
      )
    @end_time =
      (
        if match_data[:ends_at]
          Time.zone.parse(match_data[:ends_at])
        else
          @start_time + 1.hour
        end
      )

    @bot.api.send_message(
      chat_id: message.chat.id,
      text:
        "Searching for \"#{@search_query}, Singapore\"..."
    )

    @next_state = ShowSearchDataState.enter(@bot, **to_data)
  end
end

class ShowSearchDataState < BaseState
  def welcome
    # this conditional is to handle coming from SelectTimeState
    # FIXME: ugh, should be able to look at destination, but defaults to a hash with coordinate group, and doesn't have address
    unless @location_results.present?
      @location_results = Parkcheep::Geocoder.new.geocode(@search_query)
      # this is a dead end, but Google seems to always at return something
      if @location_results.empty?
        @bot.api.send_message(
          chat_id: @chat_id,
          text:
            "Could not find that destination on Google. Please try again with a different destination name!"
        )
        return
      end
      # TODO: handle Google maps returning multiple locations (rare)
      center_location = @location_results.first
      @destination = { coordinate_group: center_location[:coordinate_group] }
      @bot.api.send_message(
        chat_id: @chat_id,
        text: "Found this location: #{center_location[:address]}."
      )
      @bot.api.send_photo(
        chat_id: @chat_id,
        photo: gmaps_static_url(destination: center_location[:coordinate_group])
      )
    end

    kb = [
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: "Yes",
        callback_data: "show_carparks"
      ),
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: "No, my destination is wrong",
        callback_data: "change_destination"
      ),
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: "No, my time is wrong",
        callback_data: "change_time"
      )
    ]
    markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)

    @bot.api.send_message(
      chat_id: @chat_id,
      text: "Shall I proceed to look for carparks nearby, for the time period #{@start_time.to_fs(:short)} to #{@end_time.to_fs(:short)}?",
      reply_markup: markup
    )

    @next_state = self
  end

  def handle_callback(callback_query)
    case callback_query.data
    when "show_carparks"
      @next_state = ShowCarparksState.enter(@bot, **to_data)
    when "change_destination"
      @next_state = SearchState.enter(@bot, **to_data)
    when "change_time"
      @next_state = SelectTimeState.enter(@bot, **to_data)
    end
  end
end

class SearchState < BaseState
  def handle(message)
    @search_query = message.text
    @bot.api.send_message(
      chat_id: message.chat.id,
      text: "Searching for \"#{@search_query}, Singapore\"..."
    )
    @location_results = []
    @location_results = Parkcheep::Geocoder.new.geocode(@search_query)
    if @location_results.empty?
      @bot.api.send_message(
        chat_id: message.chat.id,
        text: "Could not find that destination on Google. Please try again with a different destination name!"
      )
      return
    end

    # TODO: handle Google maps returning multiple locations (rare)
    center_location = @location_results.first
    @bot.api.send_photo(
      chat_id: message.chat.id,
      photo: gmaps_static_url(destination: center_location[:coordinate_group])
    )
    kb = [
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: "Yes",
        callback_data: "true"
      ),
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: "No",
        callback_data: "false"
      )
    ]
    markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)

    @bot.api.send_message(
      chat_id: message.chat.id,
      text: "Found this location: #{center_location[:address]}. Is it correct?",
      reply_markup: markup
    )

    @next_state = self
  end

  def handle_callback(callback_query)
    if callback_query.data == "false"
      welcome
      return
    end

    @destination = {
      coordinate_group: @location_results.first[:coordinate_group]
    }

    @next_state = ShowSearchDataState.enter(@bot, **to_data)
  end

  def welcome
    return unless @chat_id.present?

    @bot.api.send_message(
      chat_id: @chat_id,
      text: "OK! Please type your destination again."
    )
  end
end

class SelectTimeState < BaseState
  REGEX =
  /(?<starts_at>(?>\d{4}-\d{2}-\d{2} )?(?>\d{2}:\d{2}))?(?> to (?<ends_at>(?>\d{4}-\d{2}-\d{2} )?(?>\d{2}:\d{2})))?/.freeze
  HELP_TEXT = <<~HELP
    - `[HH:MM]` e.g. 13:30
    - `[HH:MM] to [HH:MM]` e.g. 13:30 to 15:00
    - `[YYYY-MM-DD HH:MM]` e.g. 2023-04-01 13:30
  HELP

  def welcome
    @bot.api.send_message(
      chat_id: @chat_id,
      text:
        "OK! Please enter the time period in one of the following formats:\n#{HELP_TEXT}"
    )
  end

  def handle_callback(callback_query)
    if callback_query.data == "yes"
      @next_state = ShowSearchDataState.enter(@bot, **to_data)
    else
      welcome
    end
  end

  def handle(message)
    raw_text = message.text
    match_data = REGEX.match(raw_text)
    if match_data[:starts_at].nil?
      @bot.api.send_message(
        chat_id: message.chat.id,
        text:
          "Sorry, I didn't understand! Please type in one of the following formats:\n#{HELP_TEXT}"
      )
      return
    end

    @start_time =
      (
        if match_data[:starts_at]
          Time.zone.parse(match_data[:starts_at])
        else
          Time.current + 30.minutes
        end
      )
    @end_time =
      (
        if match_data[:ends_at]
          Time.zone.parse(match_data[:ends_at])
        else
          @start_time + 1.hour
        end
      )

    kb = [
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: "Yes",
        callback_data: "yes"
      ),
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: "No",
        callback_data: "no"
      )
    ]
    markup =
      Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
    @bot.api.send_message(
      chat_id: @chat_id,
      text:
        "Got the time as #{@start_time.to_fs(:short)} to #{@end_time.to_fs(:short)}, did I get it right?",
      reply_markup: markup
    )
  end

  private

  attr_reader :start_time, :end_time
end

class ShowCarparksState < BaseState
  def welcome
    show_results
  end

  def handle_callback(callback_query)
    case callback_query.data
    when "show_more_carparks"
      @carpark_results_index = @carpark_results_index + 5
      show_results
    when "/start"
      @next_state = NaturalSearchState.enter(@bot, chat_id: @chat_id)
    when "/feedback"
      @next_state = FeedbackState.enter(@bot, chat_id: @chat_id)
    end
  end

  private

  attr_reader :start_time, :end_time

  def show_results
    @carpark_results_index ||= 0
    carpark_results =
      Parkcheep::Carpark
        .search(
          destination: @destination[:coordinate_group]
        ) do |carpark_result|
          carpark_result.distance_from_destination < 1
        end[@carpark_results_index..@carpark_results_index + 4]

    @bot.api.send_message(
      chat_id: @chat_id,
      text: "Showing #{@carpark_results_index > 0 ? "next" : "first"} #{carpark_results.size} carparks within 1 km in yellow 🟡:"
    )
    @bot.api.send_photo(
      chat_id: @chat_id,
      photo:
        gmaps_static_url(
          destination: @destination[:coordinate_group],
          carparks: carpark_results.map(&:carpark)
        )
    )
    labels = %w[A B C D E F G H I J]
    carpark_results.each_with_index do |result, index|
      text =
        "#{labels[index]}: #{result.name}\n- Distance: #{result.distance_from_destination.truncate(2)} km"

      begin
        estimated_cost = result.carpark.cost(start_time, end_time)
        estimated_cost_extended = result.carpark.cost(start_time, end_time + 1.hour)

        estimated_cost_text =
        estimated_cost.nil? ? "N/A" : "$#{estimated_cost.truncate(2)} (+1 hour: $#{estimated_cost_extended.truncate(2)} total)"
        text += "\n- Estimated Cost: #{estimated_cost_text}"
      rescue Parkcheep::InvalidDateRangeError => e
        # TODO: log or report error
        estimated_cost = nil
      end

      parking_rate_text = result.carpark.cost_text(start_time, end_time)
      text +=
      "\n- Raw Parking Rates: #{parking_rate_text}" if parking_rate_text.present? &&
      estimated_cost.nil?

      # escape Telegram markdown reserved characters https://core.telegram.org/bots/api#formatting-options
      text.gsub!(
        /(\_|\*|\~|\`|\>|\#|\+|\-|\=|\||\{|\}|\.|\!|\[|\]|\(|\))/
        ) { |match| "\\#{match}" }

      coord = result.carpark.coordinate_group
      kb = [
        Telegram::Bot::Types::InlineKeyboardButton.new(
          text: "Google Maps Directions",
          url: "https://www.google.com/maps/dir/?api=1&destination=#{[coord.latitude, coord.longitude].join(",")}"
        ),
      ]
      if result.carpark.source.present?
        kb << Telegram::Bot::Types::InlineKeyboardButton.new(
          text: "View Rates",
          url: result.carpark.source.url
        )
      end
      @bot.api.send_message(
        chat_id: @chat_id,
        text:,
        parse_mode: "MarkdownV2",
        reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
      )
    end


    kb = [
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: "🚗 Start a new search",
        callback_data: "/start"
      ),
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: "🙏 Send some feedback",
        callback_data: "/feedback"
      ),
    ]
    unless carpark_results.size < 5
      kb.unshift(Telegram::Bot::Types::InlineKeyboardButton.new(
        text: "⏭️ Show next 5 carparks",
        callback_data: "show_more_carparks"
      ))
    end
    @bot.api.send_message(
      chat_id: @chat_id,
      text: "What would you like to do next?",
      reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
    )
  end
end

class FeedbackState < BaseState
  TYPE_WRONG_CARPARK_DATA = "wrong_carpark_data"
  TYPE_OTHER = "other"

  def welcome
    kb = [
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: "Wrong Carpark Data",
        callback_data: "wrong_carpark_data"
      ),
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: "Other",
        callback_data: "other"
      )
    ]
    markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)

    @bot.api.send_message(
      chat_id: @chat_id,
      text: "What type of feedback would you like to give?",
      reply_markup: markup
    )
  end

  def handle_callback(callback_query)
    feedback_type = callback_query.data
    @feedback[:type] = feedback_type

    case feedback_type
    when "wrong_carpark_data"
      @bot.api.send_message(
        chat_id: @chat_id,
        text: "Which carpark had the wrong data, and what was wrong?"
      )
    else
      @bot.api.send_message(
        chat_id: @chat_id,
        text: "Sure! What would you like to feedback?"
      )
    end
  end

  def handle(message)
    if feedback_type.nil?
      @bot.api.send_message(
        chat_id: @chat_id,
        text:
          "Sorry, I'm not a super smart bot (yet) - please select a feedback type from above first!"
      )
      return
    end

    @feedback[:message] = message.text

    @bot.api.send_message(
      chat_id: @chat_id,
      text:
        "🙇‍♂️ Thanks so much for the feedback! I'll pass it on to the team. To search again, just type /start!"
    )
    @bot.api.send_message(
      chat_id: ENV["FEEDBACK_CHAT_ID"],
      text: "Feedback received:\n#{to_data}"
    )
  end

  private

  def feedback_type
    return unless @feedback.is_a?(Hash)

    case @feedback[:type]
    when "wrong_carpark_data"
      TYPE_WRONG_CARPARK_DATA
    when "other"
      TYPE_OTHER
    else
      nil
    end
  end
end
