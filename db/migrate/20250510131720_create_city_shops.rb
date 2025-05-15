class CreateCityShops < ActiveRecord::Migration[8.0]
  def change
    create_table :city_shops do |t|
      t.references :city, null: false, foreign_key: true
      t.references :shop, null: false, foreign_key: true

      t.timestamps
    end
  end
end
