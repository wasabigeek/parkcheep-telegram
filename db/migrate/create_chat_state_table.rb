require "active_record"

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: "db.sqlite3"
)

class CreateChatStateTable < ActiveRecord::Migration[5.2]
  def up
    unless ActiveRecord::Base.connection.table_exists?(:chat_states)
      create_table :chat_states do |table|
        table.timestamps
      end
    end
  end

  def down
    if ActiveRecord::Base.connection.table_exists?(:chat_states)
      drop_table :chat_states
    end
  end
end

# Create the table
CreateChatStateTable.migrate(:up)

# Drop the table
# CreateChatStateTable.migrate(:down)
