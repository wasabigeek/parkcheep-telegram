class Parkcheep::ErrorReporter
  include Singleton

  def initialize
    @logger = Parkcheep::Logger.instance
  end

  def report(error)
    if ENV["GOOGLE_CLOUD_LOGGING"] == "true"
      Google::Cloud::ErrorReporting.report error
    else
      @logger.error(error)
    end
  end
end
