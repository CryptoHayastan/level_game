class CreatePromoUsages < ActiveRecord::Migration[8.0]
  def change
    create_table :promo_usages do |t|
      t.references :promo_code, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end
    add_index :promo_usages, [:promo_code_id, :user_id], unique: true
  end
end
