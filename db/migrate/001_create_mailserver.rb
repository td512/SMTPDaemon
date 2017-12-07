class CreateMailserver < ActiveRecord::Migration[5.0]
  def change
    create_table :inbox do |t|
      t.string :to_user
      t.string :from_address
      t.string :subject
      t.string :cc
      t.string :bcc
      t.string :priority
      t.string :date
      t.string :body
      t.string :attachments
    end
    create_table :sessions do |t|
      t.string :ip
      t.string :session_count
    end
  end
end
