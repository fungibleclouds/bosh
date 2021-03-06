# Copyright (c) 2009-2012 VMware, Inc.

module Bosh::Deployer
  class InstanceManager

    class Openstack < InstanceManager

      include InstanceManagerHelpers

      # TODO extract
      def update_spec(spec)
        properties = spec.properties

        properties["openstack"] =
          Config.spec_properties["openstack"] ||
          Config.cloud_options["properties"]["openstack"].dup

        properties["openstack"]["registry"] = Config.cloud_options["properties"]["registry"]
        properties["openstack"]["stemcell"] = Config.cloud_options["properties"]["stemcell"]

        spec.delete("networks")
      end

      def configure
        properties = Config.cloud_options["properties"]
        @ssh_user = properties["openstack"]["ssh_user"]
        @ssh_port = properties["openstack"]["ssh_port"] || 22
        @ssh_wait = properties["openstack"]["ssh_wait"] || 60

        key = properties["openstack"]["private_key"]
        err "Missing properties.openstack.private_key" unless key
        @ssh_key = File.expand_path(key)
        unless File.exists?(@ssh_key)
          err "properties.openstack.private_key '#{key}' does not exist"
        end

        uri = URI.parse(properties["registry"]["endpoint"])
        user, password = uri.userinfo.split(":", 2)
        @registry_port = uri.port

        @registry_db = Tempfile.new("bosh_registry_db")
        @registry_db_url = "sqlite://#{@registry_db.path}"

        registry_config = {
          "logfile" => "./bosh_registry.log",
          "http" => {
            "port" => uri.port,
            "user" => user,
            "password" => password
          },
          "db" => {
            "database" => @registry_db_url
          },
          "cloud" => {
            "plugin" => "openstack",
            "openstack" => properties["openstack"]
          }
        }

        @registry_config = Tempfile.new("bosh_registry_yml")
        @registry_config.write(Psych.dump(registry_config))
        @registry_config.close
      end

      def start
        configure()

        Sequel.connect(@registry_db_url) do |db|
          migrate(db)
          instances = @deployments["registry_instances"]
          db[:registry_instances].insert_multiple(instances) if instances
        end

        unless has_bosh_registry?
          err "bosh_registry command not found - " +
            "run 'gem install bosh_registry'"
        end

        cmd = "bosh_registry -c #{@registry_config.path}"

        @registry_pid = spawn(cmd)

        5.times do
          sleep 0.5
          if Process.waitpid(@registry_pid, Process::WNOHANG)
            err "`#{cmd}` failed, exit status=#{$?.exitstatus}"
          end
        end

        timeout_time = Time.now.to_f + (60 * 5)
        http_client = HTTPClient.new()
        begin
          http_client.head("http://127.0.0.1:#{@registry_port}")
          sleep 0.5
        rescue URI::Error, SocketError, Errno::ECONNREFUSED, HTTPClient::ReceiveTimeoutError => e
          if timeout_time - Time.now.to_f > 0
            retry
          else
            err "Cannot access bosh_registry: #{e.message}"
          end
        end
        logger.info("bosh_registry is ready on port #{@registry_port}")
      ensure
        @registry_config.unlink if @registry_config
      end

      def stop
        if @registry_pid && process_exists?(@registry_pid)
          Process.kill("INT", @registry_pid)
          Process.waitpid(@registry_pid)
        end

        return unless @registry_db_url

        Sequel.connect(@registry_db_url) do |db|
          @deployments["registry_instances"] = db[:registry_instances].map {|row| row}
        end

        save_state
        @registry_db.unlink if @registry_db
      end

      def wait_until_agent_ready
        tunnel(@registry_port)
        super
      end

      def discover_bosh_ip
        if exists?
          server = cloud.openstack.servers.get(state.vm_cid)
          # LP OpenStack Nova 185110:
          # Since OS API 1.1, server addresses exposes the network names
          # instead of the network types. so we need to fetch the
          # os-floating-ips and find if any of them is associated to the
          # server in order to get its public address.
          floating_ip = cloud.openstack.addresses.find {
                          |addr| addr.instance_id == server.id
                        }
          ip = floating_ip.nil? ? service_ip : floating_ip.ip
          err "Unable to discover bosh ip" if ip.nil?

          if ip != Config.bosh_ip
            Config.bosh_ip = ip
            logger.info("discovered bosh ip=#{Config.bosh_ip}")
          end
        end

        super
      end

      def service_ip
        server = cloud.openstack.servers.get(state.vm_cid)
        # LP OpenStack Nova 185110:
        # Since OS API 1.1, server addresses exposes the network names
        # instead of the network types, so we need to known which network
        # label is used in OS (label parm or "private" by default) to fetch
        # the service IP address.
        net_conf  = Config.net_conf
        net_label = net_conf["label"].nil? ? "private" : net_conf["label"]
        ip_addresses = server.addresses[net_label]
        unless ip_addresses.nil? || ip_addresses.empty?
          address = ip_addresses.select { |ip| ip["version"] == 4 }.first
          ip = address ? address["addr"] : nil
        end
        err "Unable to discover service ip" if ip.nil?
        ip
      end

      # @return [Integer] size in MiB
      def disk_size(cid)
        # OpenStack stores disk size in GiB but we work with MiB
        cloud.openstack.volumes.get(cid).size * 1024
      end

      def persistent_disk_changed?
        # since OpenStack stores disk size in GiB and we use MiB there
        # is a risk of conversion errors which lead to an unnecessary
        # disk migration, so we need to do a double conversion
        # here to avoid that
        requested = (Config.resources['persistent_disk'] / 1024.0).ceil * 1024
        requested != disk_size(state.disk_cid)
      end

      private

      # TODO this code is similar to has_stemcell_copy?
      # move the two into bosh_common later
      def has_bosh_registry?(path=ENV['PATH'])
        path.split(":").each do |dir|
          return true if File.exist?(File.join(dir, "bosh_registry"))
        end
        false
      end

      def migrate(db)
        db.create_table :registry_instances do
          primary_key :id
          column :instance_id, :text, :unique => true, :null => false
          column :settings, :text, :null => false
        end
      end

    end
  end
end
