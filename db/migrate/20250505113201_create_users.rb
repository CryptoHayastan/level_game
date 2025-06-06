class CreateUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users do |t|
      t.bigint :telegram_id
      t.string :username
      t.string :first_name
      t.string :last_name
      t.string :role
      t.string :step
      t.boolean :ban
      t.integer :balance
      t.integer :score
      t.string :referral_link
      t.integer :pending_referrer_id
      t.boolean :parent_access, default: true
      t.string :ancestry

      t.timestamps
    end
  end
end
