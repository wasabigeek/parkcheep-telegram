namespace :deploy do
  task :started do
    on roles(:bot) do
      upload! 'deploy/telegrambot.env', '/var/www/parkcheep-telegram/shared/'
      upload! 'deploy/telegrambot.service', '/var/www/parkcheep-telegram/shared/'
    end
  end

  task :published do
    on roles(:bot) do
      execute :sudo, "cp", "/var/www/parkcheep-telegram/shared/telegrambot.service", "/lib/systemd/system", "-v"
      execute :sudo, "systemctl", "daemon-reload"
      execute :sudo, "systemctl", "restart", "telegrambot.service"
    end
  end
end

