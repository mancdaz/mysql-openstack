#
# Cookbook Name:: mysql-openstack
# Recipe:: server
#
# Copyright 2012, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# replication parts inspired by https://gist.github.com/1105416

::Chef::Recipe.send(:include, Opscode::OpenSSL::Password)

include_recipe "osops-utils"
include_recipe "monitoring"
include_recipe "mysql::ruby"

# Lookup endpoint info, and properly set mysql attributes
mysql_info = get_bind_endpoint("mysql", "db")
#node.set["mysql"]["bind_address"] = mysql_info["host"]
bind_ip = get_ip_for_net("nova")
node.set["mysql"]["bind_address"] = bind_ip

# override default attributes in the upstream mysql cookbook
if platform?(%w{redhat centos amazon scientific})
    node.override["mysql"]["tunable"]["innodb_adaptive_flushing"] = false
end

# generate mysql server_id from my ip address
node.override["mysql"]["tunable"]["server_id"] = get_ip_for_net("nova").gsub(/\./, '')

# search for first_master id (1).  If found, assume we are the second server
# and configure accordingly.  If not, set our own and# assume we are the first

if node["mysql"]["myid"].nil?
  # then we have not yet been through setup - try and find first master
  masters = search(:node, "chef_environment:#{node.chef_environment} AND mysql_myid:1")

  if masters.length == 0
    # we must be first master
    Chef::Log.info("*** I AM FIRST MYSQL MASTER ***")
    if node["developer_mode"]
      node.set_unless["mysql"]["tunable"]["repl_pass"] = "replication"
    else
      node.set_unless["mysql"]["tunable"]["repl_pass"] = secure_password
    end

    node.set["mysql"]["auto-increment-offset"] = "1"

    #now we have set the necessary tunables, install the mysql server
    include_recipe "mysql::server"

    # since we are first master, create the replication user
    mysql_connection_info = {:host => bind_ip , :username => 'root', :password => node['mysql']['server_root_password']}

    mysql_database_user 'repl' do
      connection mysql_connection_info
      password node["mysql"]["tunable"]["repl_pass"]
      action :create
    end

    mysql_database_user 'repl' do
      connection mysql_connection_info
      privileges ['REPLICATION SLAVE']
      action :grant
      host '%'
    end

    # set this last so we can only be found when we are finished
    node.set_unless["mysql"]["myid"] = "1"

  elsif masters.length == 1
    # then we are second master
    Chef::Log.info("*** I AM SECOND MYSQL MASTER ***")
    first_master = masters.first
    node.set_unless["mysql"]["tunable"]["repl_pass"] = first_master["mysql"]["tunable"]["repl_pass"]

    node.set["mysql"]["tunable"]["auto-increment-offset"] = "2"

    #now we have set the necessary tunables, install the mysql server
    include_recipe "mysql::server"

    first_master_ip = get_ip_for_net('nova', first_master)
    # connect to master
    ruby_block "configure slave" do
      block do
        require 'rubygems'
        Gem.clear_paths
        require 'mysql'

        mysql_conn = Mysql.new(bind_ip, "root", node["mysql"]["server_root_password"])
        command = %Q{
        CHANGE MASTER TO
          MASTER_HOST="#{first_master_ip}",
          MASTER_USER="repl",
          MASTER_PASSWORD="#{node["mysql"]["tunable"]["repl_pass"]}",
          MASTER_LOG_FILE="#{node["mysql"]["tunable"]["log_bin"]}.000001",
          MASTER_LOG_POS=0;
          }
          Chef::Log.info "Sending start replication command to mysql: "
          Chef::Log.info "#{command}"

        mysql_conn.query("stop slave")
        mysql_conn.query(command)
        mysql_conn.query("start slave")

      end
    end

    # set this last so we can only be found when we are finished
    node.set_unless["mysql"]["myid"] = 2

  elsif masters.length > 1
    # error out here as something is wrong
    Chef::Application.fatal! "I discovered multiple mysql first masters - there can be only one!"

  end

end

if node['mysql']['myid'] == '1'
  # we were the first master, but have we connected back to the second master yet?
  second_master = search(:node, "chef_environment:#{node.chef_environment} AND mysql_myid:2")

  if second_master == 1
    Chef::Log.info("I am the first master, and I have found the second master")
    Chef::Log.info("Attempting to connect back to second master as a slave")

    second_master_ip = get_ip_for_net('nova', second_master[0])

    # attempt to connect to second master as a slave
    ruby_block "configure slave" do
      block do
        require 'rubygems'
        Gem.clear_paths
        require 'mysql'

        mysql_conn = Mysql.new(bind_ip, "root", node["mysql"]["server_root_password"])
        command = %Q{
        CHANGE MASTER TO
          MASTER_HOST="#{second_master_ip}",
          MASTER_USER="repl",
          MASTER_PASSWORD="#{node["mysql"]["tunable"]["repl_pass"]}",
          MASTER_LOG_FILE="#{node["mysql"]["tunable"]["log_bin"]}.000001",
          MASTER_LOG_POS=0;
          }
        Chef::Log.info "Sending start replication command to mysql: "
        Chef::Log.info "#{command}"

        mysql_conn.query("stop slave")
        mysql_conn.query(command)
        mysql_conn.query("start slave")
      end

      not_if do
        #TODO this fails if mysql is not running - check first
        mysql_conn = Mysql.new(bind_ip, "root", node["mysql"]["server_root_password"])
        slave_sql_running = ""
        mysql_conn.query("show slave status") {|r| r.each_hash {|h| slave_sql_running = h['Slave_SQL_Running'] } }
        slave_sql_running == "Yes"
      end

    end
  else
  Chef::Log.info("I am the first master, but the second master does not exist yet")
  end
end




# Cleanup the craptastic mysql default users
cookbook_file "/tmp/cleanup_anonymous_users.sql" do
  source "cleanup_anonymous_users.sql"
  mode "0644"
end

execute "cleanup-default-users" do
  command "#{node['mysql']['mysql_bin']} -u root #{node['mysql']['server_root_password'].empty? ? '' : '-p' }\"#{node['mysql']['server_root_password']}\" < /tmp/cleanup_anonymous_users.sql"
  only_if "#{node['mysql']['mysql_bin']} -u root #{node['mysql']['server_root_password'].empty? ? '' : '-p' }\"#{node['mysql']['server_root_password']}\" -e 'show databases;' | grep test"
end

# Moving out of mysql cookbook
template "/root/.my.cnf" do
  source "dotmycnf.erb"
  owner "root"
  group "root"
  mode "0600"
  not_if "test -f /root/.my.cnf"
  variables :rootpasswd => node['mysql']['server_root_password']
end

platform_options = node["mysql"]["platform"]

monitoring_procmon "mysqld" do
  service_name = platform_options["mysql_service"]
  process_name service_name
  script_name service_name
end

# This is going to fail for an external database server...
monitoring_metric "mysqld-proc" do
  type "proc"
  proc_name "mysqld"
  proc_regex platform_options["mysql_service"]

  alarms(:failure_min => 1.0)
end

monitoring_metric "mysql" do
  type "mysql"
  host mysql_info["host"]
  user "root"
  password node["mysql"]["server_root_password"]
  port mysql_info["port"]

  alarms("max_connections" => {
           :warning_max => node["mysql"]["tunable"]["max_connections"].to_i * 0.8,
           :failure_max => node["mysql"]["tunable"]["max_connections"].to_i * 0.9
         })

end
