class CreateShops < ActiveRecord::Migration[8.0]
  def change
    create_table :shops do |t|
      t.references :user, foreign_key: true
      t.string :name
      t.string :link
      t.boolean :online
      t.datetime :online_since

      t.timestamps
    end
  end
end