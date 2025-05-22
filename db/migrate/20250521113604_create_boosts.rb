class CreateBoosts < ActiveRecord::Migration[8.0]
  def change
    create_table :boosts do |t|
      t.references :user, null: false, foreign_key: true
      t.datetime :activated_at

      t.timestamps
    end
  end
end
