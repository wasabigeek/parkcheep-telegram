require "spec_helper"
require "bot_runner"

RSpec.describe BotRunner do
  describe "#handle_message with Telegram::Bot::Types::Message" do
    before { ENV["TELEGRAM_TOKEN"] = "123" }
    after { ENV["TELEGRAM_TOKEN"] = nil }
    it "enters the SearchState on /start" do
      bot = double("bot", api: double("api", send_message: nil))
      message = Telegram::Bot::Types::Message.new(text: "/start")
      allow(message).to receive(:chat).and_return(double("chat", id: 1))

      runner = BotRunner.new
      runner.handle_message(bot, message)

      expect(runner.send(:retrieve_chat_state, bot, 1)).to be_a(SearchState)
    end
  end
end
