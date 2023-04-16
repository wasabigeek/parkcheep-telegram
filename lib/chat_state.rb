require "active_record"

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: "db.sqlite3"
)

class ChatState < ActiveRecord::Base
end
