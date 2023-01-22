require 'telegram/bot'

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
      @bot.api.send_message(chat_id: message.chat.id, text: "Searching for carparks near #{@search_query}")
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
