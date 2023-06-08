require "spec_helper"
require "bot_runner"

RSpec.describe BotRunner do
  describe "#handle_message with Telegram::Bot::Types::Message" do
    before do
      ENV["TELEGRAM_TOKEN"] = "123"
      ENV["GOOGLE_MAPS_API_KEY"] = "456"
      Time.zone = "Asia/Singapore"
    end
    after do
      ENV["TELEGRAM_TOKEN"] = nil
      ENV["GOOGLE_MAPS_API_KEY"] = nil
    end
    it "integration test" do
      api = double("api", send_message: nil)
      bot = double("bot", api:)

      # TODO: need to redo the tests
      # start
      message = Telegram::Bot::Types::Message.new(text: "/start")
      allow(message).to receive(:chat).and_return(double("chat", id: 1))
      expect(api).to receive(:send_message).with(
        { chat_id: 1, text: /^👋 Where in Singapore are you going?/ }
      )

      runner = BotRunner.new
      runner.handle_message(bot, message)

      expect(runner.send(:retrieve_chat_state, bot, 1)).to be_a(NaturalSearchState)

      # searching, no location found
      expect_any_instance_of(Parkcheep::Geocoder).to receive(:geocode).with(
        "changi airport"
      ).and_return([])
      expect(api).to receive(:send_message).with(
        { chat_id: 1, text: "Searching for \"changi airport, Singapore\"..." }
      ).ordered
      expect(api).to receive(:send_message).with(
        { chat_id: 1, text: "Could not find that destination on Google. Please try again with a different destination name!" }
      ).ordered

      message2 = Telegram::Bot::Types::Message.new(text: "changi airport")
      allow(message2).to receive(:chat).and_return(double("chat", id: 1))
      runner.handle_message(bot, message2)

      # this isn't quite right, but it's good enough for now
      expect(runner.send(:retrieve_chat_state, bot, 1)).to be_a(ShowSearchDataState)
    end
  end
end
