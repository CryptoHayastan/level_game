class CreatePromoCodes < ActiveRecord::Migration[8.0]
  def change
    create_table :promo_codes do |t|
      t.string :code
      t.references :shop, null: false, foreign_key: true
      t.integer :product_type
      t.datetime :expires_at

      t.timestamps
    end
    add_index :promo_codes, :code, unique: true
  end
end
