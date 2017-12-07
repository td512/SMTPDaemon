require "rubygems"
require "bundler/setup"

require 'pg'
require 'active_record'
require 'yaml'

namespace :db do

  desc "Migrate the db"
  task :migrate do
    connection_details = YAML.load(File.read(File.expand_path('../database.yml', __FILE__)))
    ActiveRecord::Base.establish_connection(connection_details)
    ActiveRecord::Migrator.migrate("db/migrate/")
  end

  desc "Create the db"
  task :create do
    connection_details = YAML.load(File.read(File.expand_path('../database.yml', __FILE__)))
    admin_connection = connection_details.merge({'database'=> 'postgres',
                                                'schema_search_path'=> 'public'})
    ActiveRecord::Base.establish_connection(admin_connection)
    ActiveRecord::Base.connection.create_database(connection_details.fetch('database'))
  end

  desc "drop the db"
  task :drop do
    connection_details = YAML.load(File.read(File.expand_path('../database.yml', __FILE__)))
    admin_connection = connection_details.merge({'database'=> 'postgres',
                                                'schema_search_path'=> 'public'})
    ActiveRecord::Base.establish_connection(admin_connection)
    ActiveRecord::Base.connection.drop_database(connection_details.fetch('database'))
  end
end
