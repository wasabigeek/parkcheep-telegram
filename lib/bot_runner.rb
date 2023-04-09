require "telegram/bot"
require "active_support/hash_with_indifferent_access"
require "active_support/time"
require "parkcheep"
require_relative "states"

class BotRunner
  def initialize
    @token = ENV["TELEGRAM_TOKEN"] || File.read("telegram_token.txt").strip
    @chat_state_store =
      Hash.new { |_, k| { chat_id: k, state: BaseState.to_s } }
  end

  def handle_message(bot, message)
    chat_id = nil
    begin
      case message
      when Telegram::Bot::Types::Message
        puts "#{message.class}"
        chat_id = message.chat.id

        case message.text
        when "/start"
          state = SearchState.enter(bot, chat_id:)
        when "/stop"
          state = BaseState.enter(bot, chat_id:)
        else
          state = retrieve_chat_state(bot, chat_id)
          state.handle(message)
        end

        store_chat_state(chat_id, state.next_state)
      when Telegram::Bot::Types::CallbackQuery
        chat_id = message.from.id

        puts "CallbackQuery ID #{message.id}: #{message.data}"
        state = retrieve_chat_state(bot, chat_id)
        state.handle_callback(message)
        store_chat_state(chat_id, state.next_state)
      end
    rescue StandardError => e
      bot.api.send_message(
        chat_id:,
        text: "Oops! Seems like we had some issues. I'm going to reboot, sorry!"
      )
      puts @chat_state_store
      raise
    end
  end

  def run
    puts "Preloading Parkcheep..."
    Time.zone = "Asia/Singapore"
    Parkcheep.preload
    puts "Preloaded Parkcheep!"

    Telegram::Bot::Client.run(@token) do |bot|
      bot.api.set_my_commands(
        commands: [
          Telegram::Bot::Types::BotCommand.new(
            command: "start",
            description: "Start finding carparks at your destination"
          )
        ]
      )

      bot.listen do |message|
        handle_message(bot, message)

        # TODO: remove
        puts @chat_state_store
      end
    end
  end

  private

  def retrieve_chat_state(bot, chat_id)
    data = @chat_state_store[chat_id]
    state_class = data[:state].constantize
    state_class.init_from_data(bot, **data)
  end

  def store_chat_state(chat_id, state)
    @chat_state_store[chat_id] = state.to_data
  end
end
