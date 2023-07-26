class Parkcheep::Logger
  include Singleton

  delegate :debug, :info, :warn, :error, :fatal, :unknown, to: :logger

  def initialize
    @logger = create_logger
  end

  private

  attr_reader :logger

  def create_logger
    if ENV["GOOGLE_CLOUD_LOGGING"] == "true"
      logging = Google::Cloud::Logging.new
      resource = logging.resource "gce_instance", labels: {}

      logging.logger "parkcheep-telegram", resource
    else
      Logger.new(STDOUT, progname: "parkcheep-telegram")
    end
  end
end
