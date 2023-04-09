require "spec_helper"
require "bot_runner"

RSpec.describe BotRunner do
  describe "#handle_message with Telegram::Bot::Types::Message" do
    before do
      ENV["TELEGRAM_TOKEN"] = "123"
      Time.zone = "Asia/Singapore"
    end
    after { ENV["TELEGRAM_TOKEN"] = nil }
    it "enters the SearchState on /start" do
      api = double("api", send_message: nil)
      bot = double("bot", api:)
      message = Telegram::Bot::Types::Message.new(text: "/start")
      allow(message).to receive(:chat).and_return(double("chat", id: 1))

      runner = BotRunner.new
      runner.handle_message(bot, message)

      expect(runner.send(:retrieve_chat_state, bot, 1)).to be_a(SearchState)
      expect(api).to have_received(:send_message).with(
        { chat_id: 1, text: "👋 Hello! Please type your destination." }
      )
    end
  end
end
