class CreateMessageCounts < ActiveRecord::Migration[8.0]
  def change
    create_table :message_counts do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :count

      t.timestamps
    end
  end
end
