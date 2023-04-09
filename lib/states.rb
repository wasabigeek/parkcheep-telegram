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
      end_time: @end_time&.iso8601
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
        text: "No locations found."
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

    @next_state = SelectTimeState.enter(@bot, **to_data)
  end

  def welcome
    return unless @chat_id.present?

    @bot.api.send_message(
      chat_id: @chat_id,
      text: "👋 Hello! Please type your destination."
    )
  end
end

class SelectTimeState < BaseState
  def welcome
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
    markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
    @bot.api.send_message(
      chat_id: @chat_id,
      text:
        "The time period for parking is currently set to #{start_time.to_fs(:short)} to #{end_time.to_fs(:short)}, is this correct?",
      reply_markup: markup
    )
  end

  def handle_callback(callback_query)
    if callback_query.data == "yes"
      @next_state = ShowCarparksState.enter(@bot, **to_data)
    else
      @bot.api.send_message(
        chat_id: @chat_id,
        text:
          "Please enter a start time in `HH:MM` or `YYYY-MM-DD HH:MM` format (e.g. 13:15, or 2022-11-13 13:15). Changing the duration is not supported yet 🙇‍♂️."
      )
    end
  end

  def handle(message)
    begin
      @start_time = Time.zone.parse(message.text)
      @end_time = start_time + 1.hour
      welcome
    rescue ArgumentError => e
      puts e
      @bot.api.send_message(
        chat_id: message.chat.id,
        text:
          "Could not parse \"#{message.text}\", please try again in HH:MM format."
      )
    end
  end

  private

  attr_reader :start_time, :end_time
end

class ShowCarparksState < BaseState
  def welcome
    carpark_results =
      Parkcheep::Carpark
        .search(
          destination: @destination[:coordinate_group]
        ) { |carpark_result| carpark_result.distance_from_destination < 1 }
        .first(5)

    @bot.api.send_message(
      chat_id: @chat_id,
      text: "Showing nearest #{carpark_results.size} carparks in yellow 🟡:"
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
      estimated_cost = result.carpark.cost(start_time, end_time)
      estimated_cost_text =
        estimated_cost.nil? ? "N/A" : "$#{estimated_cost.truncate(2)}"
      text =
        "#{labels[index]}: #{result.name}\n- Distance: #{result.distance_from_destination.truncate(2)} km"
      text += "\n- Estimated Cost: #{estimated_cost_text}"

      parking_rate_text = result.carpark.cost_text(start_time, end_time)
      text +=
        "\n- Raw Parking Rates: #{parking_rate_text}" if parking_rate_text.present? &&
        estimated_cost.nil?

      coord = result.carpark.coordinate_group
      # $gmaps$ is a workaround to not escape inline url
      text +=
        "\n- $gmaps$https://www.google.com/maps/dir/?api=1&destination=#{[coord.latitude, coord.longitude].join(",")}$gmaps$"

      # escape Telegram markdown reserved characters https://core.telegram.org/bots/api#formatting-options
      text.gsub!(
        /(\_|\*|\~|\`|\>|\#|\+|\-|\=|\||\{|\}|\.|\!|\[|\]|\(|\))/
      ) { |match| "\\#{match}" }
      text.gsub!(/\$gmaps\$(\S+)\$gmaps\$/, "[Google Maps Directions](\\1)")

      @bot.api.send_message(chat_id: @chat_id, text:, parse_mode: "MarkdownV2")
    end
  end

  private

  attr_reader :start_time, :end_time
end
