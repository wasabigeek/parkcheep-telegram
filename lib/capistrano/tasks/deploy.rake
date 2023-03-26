namespace :deploy do
  task :started do
    on roles(:bot) do
      upload! 'deploy/telegrambot.env', '/var/www/parkcheep-telegram/shared/'
      upload! 'deploy/telegrambot.service', '/var/www/parkcheep-telegram/shared/'
      upload! 'deploy/google_cloud_ops_agent_config.yaml', '/etc/google-cloud-ops-agent/config.yaml'
    end
  end

  task :published do
    on roles(:bot) do
      within('/var/www/parkcheep-telegram/current') do
        execute "/home/nick/.rvm/bin/rvm", "3.1.3", "do", "bundle", "install"
      end
      execute :sudo, "cp", "/var/www/parkcheep-telegram/shared/telegrambot.service", "/lib/systemd/system", "-v"
      execute :sudo, "systemctl", "daemon-reload"
      execute :sudo, "systemctl", "restart", "telegrambot.service"
      execute :sudo, "service", "google-cloud-ops-agent", "restart"
    end
  end
end

