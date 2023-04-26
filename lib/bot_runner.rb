require "telegram/bot"
require "active_support/hash_with_indifferent_access"
require "active_support/time"
require "parkcheep"
require "json"
if ENV["GOOGLE_CLOUD_LOGGING"] == "true"
  require "google/cloud/logging"
  require "google/cloud/error_reporting"
end

require_relative "states"

class Parkcheep::Logger
  def self.create
    if ENV["GOOGLE_CLOUD_LOGGING"] == "true"
      logging = Google::Cloud::Logging.new
      resource = logging.resource "gce_instance", labels: {}

      logging.logger "parkcheep-telegram", resource
    else
      Logger.new(STDOUT, progname: "parkcheep-telegram")
    end
  end
end

class Parkcheep::ErrorReporter
  def initialize(logger:)
    @logger = logger
  end

  def report(error)
    if ENV["GOOGLE_CLOUD_LOGGING"] == "true"
      Google::Cloud::ErrorReporting.report error
    else
      @logger.error(error)
    end
  end
end

class BotRunner
  def initialize(logger: Parkcheep::Logger.create)
    @token = ENV["TELEGRAM_TOKEN"] || File.read("telegram_token.txt").strip
    @chat_state_store =
      Hash.new { |_, k| { chat_id: k, state: BaseState.to_s } }
    @logger = logger
    @error_reporter = Parkcheep::ErrorReporter.new(logger:)
  end

  def handle_message(bot, message)
    chat_id = nil
    begin
      case message
      when Telegram::Bot::Types::Message
        logger.debug("#{message.class}")
        chat_id = message.chat.id

        case message.text
        when "/start"
          state = NaturalSearchState.enter(bot, chat_id:)
        when "/stop"
          state = BaseState.enter(bot, chat_id:)
        when "/dev_test"
          raise "Example Error"
        else
          state = retrieve_chat_state(bot, chat_id)
          state.handle(message)
        end

        store_chat_state(chat_id, state.next_state)
      when Telegram::Bot::Types::CallbackQuery
        chat_id = message.from.id

        logger.debug("CallbackQuery ID #{message.id}: #{message.data}")
        state = retrieve_chat_state(bot, chat_id)
        state.handle_callback(message)
        store_chat_state(chat_id, state.next_state)
      end

      logger.debug({ chat_state_data: @chat_state_store[chat_id] })
    rescue StandardError => e
      bot.api.send_message(
        chat_id:,
        text: "Oops! Seems like we had some issues. I'm going to reboot, sorry!"
      )
      logger.debug({ chat_state_data: @chat_state_store[chat_id] })
      # re-raising can cause an infinite loop if the last message can cause the error again.
      # I think if the Telegram client is interrupted, when it next restarts it will pull the same message again.
      error_reporter.report(e)
      state = BaseState.enter(bot, chat_id:)
      store_chat_state(chat_id, state.next_state)
    end
  end

  def run
    logger.info("Preloading Parkcheep...")
    Time.zone = "Asia/Singapore"
    Parkcheep.preload
    logger.info("Preloaded Parkcheep!")

    Telegram::Bot::Client.run(@token) do |bot|
      bot.api.set_my_commands(
        commands: [
          Telegram::Bot::Types::BotCommand.new(
            command: "start",
            description: "Start finding carparks at your destination"
          )
        ]
      )

      bot.listen { |message| handle_message(bot, message) }
    end
  end

  private

  attr_reader :logger, :error_reporter

  def retrieve_chat_state(bot, chat_id)
    data = @chat_state_store[chat_id]
    state_class = data[:state].constantize
    state_class.init_from_data(bot, **data)
  end

  def store_chat_state(chat_id, state)
    @chat_state_store[chat_id] = state.to_data
  end
end
