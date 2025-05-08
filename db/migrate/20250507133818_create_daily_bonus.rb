class CreateDailyBonus < ActiveRecord::Migration[8.0]
  def change
    create_table :daily_bonus do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :bonus_day, default: 0
      t.datetime :last_collected_at

      t.timestamps
    end
  end
end
